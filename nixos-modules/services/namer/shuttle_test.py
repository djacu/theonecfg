import os
import tempfile
import time
import unittest
from pathlib import Path

import shuttle


class FakeApi:
    """Routes (method, path) to canned responses; records calls."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def get(self, path, params=None):
        self.calls.append(("GET", path, params))
        route = self.routes[("GET", path)]
        return route(params) if callable(route) else route

    def post(self, path, body):
        self.calls.append(("POST", path, body))
        return self.routes[("POST", path)]


def queue_page(records, total):
    return {"page": 1, "pageSize": 1000, "totalRecords": total, "records": records}


class TestFeedDecisions(unittest.TestCase):
    def test_list_import_blocked_filters_and_dedupes(self):
        records = [
            # two rows, same download (per-episode rows) -> one entry
            {"downloadId": "AAA", "status": "completed", "trackedDownloadStatus": "warning",
             "trackedDownloadState": "importPending", "seriesId": 5},
            {"downloadId": "AAA", "status": "completed", "trackedDownloadStatus": "warning",
             "trackedDownloadState": "importPending", "seriesId": 5},
            # series-unresolvable shape: state stays "downloading" forever
            {"downloadId": "BBB", "status": "completed", "trackedDownloadStatus": "warning",
             "trackedDownloadState": "downloading"},
            # still actually downloading -> excluded (status not completed)
            {"downloadId": "CCC", "status": "downloading", "trackedDownloadStatus": "ok",
             "trackedDownloadState": "downloading"},
            # healthy import pending (no warning) -> excluded
            {"downloadId": "DDD", "status": "completed", "trackedDownloadStatus": "ok",
             "trackedDownloadState": "importPending"},
        ]
        api = FakeApi({("GET", "/api/v3/queue"): lambda p: queue_page(records, len(records))})
        self.assertEqual(shuttle.list_import_blocked(api), {"AAA", "BBB"})

    def test_feedable(self):
        self.assertTrue(shuttle.feedable({"path": "/d/x.mp4", "episodes": [], "rejections": []}))
        self.assertTrue(shuttle.feedable({"path": "/d/x.mp4", "episodes": [{"id": 1}],
                                          "rejections": [{"reason": "Unknown", "type": "permanent"}]}))
        self.assertFalse(shuttle.feedable({"path": "/d/x.mp4", "episodes": [{"id": 1}], "rejections": []}))

    def test_is_video_and_link_names(self):
        exts = ["mp4", "wmv"]
        self.assertTrue(shuttle.is_video("a.scene.MP4", exts))
        self.assertFalse(shuttle.is_video("a.nfo", exts))
        n1 = shuttle.link_name("AAA", "/d/cd1/x.mp4")
        n2 = shuttle.link_name("AAA", "/d/cd2/x.mp4")
        self.assertTrue(n1.startswith("AAA-") and n1.endswith("-x.mp4"))
        self.assertNotEqual(n1, n2)  # same basename, different paths
        self.assertNotEqual(shuttle.state_key("AAA", "/d/cd1/x.mp4"),
                            shuttle.state_key("AAA", "/d/cd2/x.mp4"))


class TestStateAndFeed(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.scratch = self.root / "scratch"
        for d in ("watch", "work", "failed", "dest"):
            (self.scratch / d).mkdir(parents=True)
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def env(self):
        return {"url": "http://x", "key_file": "", "scratch": str(self.scratch),
                "state_file": str(self.root / "state.json"),
                "exts": ["mp4"], "max_attempts": 168}

    def test_state_roundtrip(self):
        path = self.root / "state.json"
        state = shuttle.load_state(str(path))
        self.assertEqual(state["entries"], {})
        state["entries"]["k"] = {"inode": 1}
        shuttle.save_state(str(path), state)
        self.assertEqual(shuttle.load_state(str(path))["entries"]["k"]["inode"], 1)
        # atomic write: the temp file is gone after the rename
        self.assertFalse(Path(str(path) + ".new").exists())

    def test_feed_links_and_records(self):
        src = self.downloads / "release"
        src.mkdir()
        video = src / "garbled.mp4"
        video.write_bytes(b"x" * 128)
        other = src / "sidecar.nfo"
        other.write_bytes(b"y")
        items = [
            {"path": str(video), "episodes": [], "rejections": [], "downloadId": "AAA"},
            {"path": str(other), "episodes": [], "rejections": [], "downloadId": "AAA"},
        ]
        api = FakeApi({
            ("GET", "/api/v3/queue"): lambda p: queue_page(
                [{"downloadId": "AAA", "status": "completed",
                  "trackedDownloadStatus": "warning",
                  "trackedDownloadState": "importPending"}], 1),
            ("GET", "/api/v3/manualimport"): items,
        })
        state = shuttle.load_state(self.env()["state_file"])
        counters = shuttle.feed(api, self.env(), state)
        link = self.scratch / "watch" / shuttle.link_name("AAA", str(video))
        self.assertTrue(link.exists())
        self.assertEqual(link.stat().st_ino, video.stat().st_ino)
        entry = state["entries"][shuttle.state_key("AAA", str(video))]
        self.assertEqual(entry["status"], "fed")
        self.assertEqual(entry["original_path"], str(video))
        # .nfo is not a video: not linked, not recorded
        self.assertNotIn(shuttle.state_key("AAA", str(other)), state["entries"])
        self.assertEqual(counters["fed"], 1)
        # manualimport GET must never carry a seriesId (library-mode trap)
        mi_calls = [c for c in api.calls if c[1] == "/api/v3/manualimport"]
        for _, _, params in mi_calls:
            self.assertNotIn("seriesId", params)
        # idempotent second run
        counters2 = shuttle.feed(api, self.env(), state)
        self.assertEqual(counters2["fed"], 0)

    def test_feed_duplicate_basenames_in_one_pack(self):
        src = self.downloads / "pack"
        (src / "cd1").mkdir(parents=True)
        (src / "cd2").mkdir(parents=True)
        v1 = src / "cd1" / "scene.mp4"
        v2 = src / "cd2" / "scene.mp4"
        v1.write_bytes(b"a" * 64)
        v2.write_bytes(b"b" * 64)
        api = FakeApi({
            ("GET", "/api/v3/queue"): lambda p: queue_page(
                [{"downloadId": "PACK", "status": "completed",
                  "trackedDownloadStatus": "warning",
                  "trackedDownloadState": "importPending"}], 1),
            ("GET", "/api/v3/manualimport"): [
                {"path": str(v1), "episodes": [], "rejections": [], "downloadId": "PACK"},
                {"path": str(v2), "episodes": [], "rejections": [], "downloadId": "PACK"},
            ],
        })
        state = shuttle.load_state(self.env()["state_file"])
        counters = shuttle.feed(api, self.env(), state)
        self.assertEqual(counters["fed"], 2)
        self.assertEqual(len(state["entries"]), 2)
        self.assertEqual(len(list((self.scratch / "watch").iterdir())), 2)

    def test_feed_unsupported_extension_still_pins(self):
        src = self.downloads / "r2"
        src.mkdir()
        video = src / "clip.wmv"
        video.write_bytes(b"x" * 64)
        api = FakeApi({
            ("GET", "/api/v3/queue"): lambda p: queue_page(
                [{"downloadId": "BBB", "status": "completed",
                  "trackedDownloadStatus": "warning",
                  "trackedDownloadState": "downloading"}], 1),
            ("GET", "/api/v3/manualimport"): [
                {"path": str(video), "episodes": [], "rejections": [], "downloadId": "BBB"}],
        })
        state = shuttle.load_state(self.env()["state_file"])
        counters = shuttle.feed(api, self.env(), state)
        # exts=["mp4"] -> wmv is unsupported for namer but still hardlinked (pack pin)
        link = self.scratch / "watch" / shuttle.link_name("BBB", str(video))
        self.assertTrue(link.exists())
        self.assertEqual(counters["unsupported_extension"], 1)
        self.assertEqual(state["entries"][shuttle.state_key("BBB", str(video))]["status"], "fed")


if __name__ == "__main__":
    unittest.main()
