import os
import tempfile
import time
import unittest
from collections import Counter
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


class TestHarvestHelpers(unittest.TestCase):
    def test_canonical_stem_and_site(self):
        p = "/s/dest/Mom Swap - 2026-08-13 - Some Title [WEBDL-1080p].mp4"
        self.assertEqual(shuttle.canonical_stem(p),
                         "Mom Swap - 2026-08-13 - Some Title [WEBDL-1080p]")
        self.assertEqual(shuttle.site_of(shuttle.canonical_stem(p)), "Mom Swap")

    def test_normalize_title(self):
        self.assertEqual(shuttle.normalize_title("Bang Bros 18!"), "bangbros18")

    def test_already_imported(self):
        api = FakeApi({("GET", "/api/v3/history"): {
            "records": [
                {"eventType": "downloadFolderImported", "episodeId": 7},
                {"eventType": "downloadFolderImported", "episodeId": 9},
            ]}})
        self.assertEqual(shuttle.already_imported(api, "AAA"), {7, 9})

    def test_ensure_series_requires_exact_normalized_match(self):
        lookup = [{"title": "Mom Swap", "tvdbId": 123}]
        api = FakeApi({
            ("GET", "/api/v3/series/lookup"): lookup,
            ("GET", "/api/v3/series"): [
                {"id": 1, "qualityProfileId": 4, "rootFolderPath": "/tank0/media/adult"}],
            ("POST", "/api/v3/series"): {"id": 42},
        })
        self.assertEqual(shuttle.ensure_series(api, "Mom Swap"), 42)
        body = [c for c in api.calls if c[0] == "POST"][0][2]
        self.assertEqual(body["rootFolderPath"], "/tank0/media/adult")
        self.assertNotIn("seasonFolder", body)
        api2 = FakeApi({("GET", "/api/v3/series/lookup"): [{"title": "Mom Swap Extra", "tvdbId": 9}]})
        self.assertIsNone(shuttle.ensure_series(api2, "Mom Swap"))


class TestHarvest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.scratch = self.root / "scratch"
        for d in ("watch", "work", "failed", "dest"):
            (self.scratch / d).mkdir(parents=True)
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()
        self.state_file = str(self.root / "state.json")

    def tearDown(self):
        self.tmp.cleanup()

    def env(self):
        return {"url": "http://x", "key_file": "", "scratch": str(self.scratch),
                "state_file": self.state_file, "exts": ["mp4"], "max_attempts": 168}

    def make_rescued_file(self, download_id="AAA",
                          canonical="Mom Swap - 2026-08-13 - T [WEBDL-1080p].mp4"):
        src = self.downloads / "rel"
        src.mkdir(exist_ok=True)
        video = src / "garbled.mp4"
        video.write_bytes(b"x" * 256)
        dest = self.scratch / "dest" / canonical
        os.link(video, dest)
        st = video.stat()
        state = shuttle.load_state(self.state_file)
        state["entries"][shuttle.state_key(download_id, str(video))] = {
            "inode": st.st_ino, "size": st.st_size, "download_id": download_id,
            "original_path": str(video),
            "link_name": shuttle.link_name(download_id, str(video)),
            "fed_at": 0, "status": "fed", "attempts": 0, "last_refresh": 0}
        return video, dest, state

    def test_harvest_imports_and_unlinks(self):
        video, dest, state = self.make_rescued_file()
        parse = {"series": {"id": 5},
                 "episodes": [{"id": 7, "hasFile": False}],
                 "parsedEpisodeInfo": {"quality": {"quality": {"id": 3}}}}
        mi_item = {"path": str(video), "episodes": [], "rejections": [],
                   "downloadId": "AAA", "folderName": "rel", "releaseGroup": "",
                   "quality": {"quality": {"id": 3, "name": "WEBDL-1080p"}},
                   "languages": [{"id": 1, "name": "English"}]}
        api = FakeApi({
            ("GET", "/api/v3/parse"): parse,
            ("GET", "/api/v3/manualimport"): [mi_item],
            ("POST", "/api/v3/command"): {"id": 99},
            ("GET", "/api/v3/command/99"): {"status": "completed"},
            ("GET", "/api/v3/history"): {"records": [
                {"eventType": "downloadFolderImported", "episodeId": 7}]},
        })
        counters = shuttle.harvest(api, self.env(), state)
        self.assertEqual(counters["imported"], 1)
        self.assertFalse(dest.exists())
        key = shuttle.state_key("AAA", str(video))
        self.assertEqual(state["entries"][key]["status"], "imported")
        cmd = [c for c in api.calls if c[0] == "POST" and c[1] == "/api/v3/command"][0][2]
        self.assertEqual(cmd["name"], "ManualImport")
        self.assertEqual(cmd["importMode"], "copy")
        f = cmd["files"][0]
        self.assertEqual(f["path"], str(video))
        self.assertEqual(f["downloadId"], "AAA")
        self.assertEqual(f["episodeIds"], [7])
        self.assertEqual(f["seriesId"], 5)
        self.assertIsNotNone(f["quality"])
        self.assertIsNotNone(f["languages"])

    def test_harvest_hasfile_own_history_closes(self):
        video, dest, state = self.make_rescued_file()
        api = FakeApi({
            ("GET", "/api/v3/parse"): {"series": {"id": 5},
                                       "episodes": [{"id": 7, "hasFile": True}]},
            ("GET", "/api/v3/history"): {"records": [
                {"eventType": "downloadFolderImported", "episodeId": 7}]},
        })
        counters = shuttle.harvest(api, self.env(), state)
        self.assertEqual(counters["imported_replay"], 1)
        self.assertFalse(dest.exists())
        self.assertEqual(
            state["entries"][shuttle.state_key("AAA", str(video))]["status"], "imported")

    def test_harvest_hasfile_foreign_parks_as_needs_human(self):
        video, dest, state = self.make_rescued_file()
        api = FakeApi({
            ("GET", "/api/v3/parse"): {"series": {"id": 5},
                                       "episodes": [{"id": 7, "hasFile": True}]},
            ("GET", "/api/v3/history"): {"records": []},
        })
        counters = shuttle.harvest(api, self.env(), state)
        self.assertEqual(counters["needs_human_duplicate"], 1)
        self.assertTrue(dest.exists())  # never auto-unlink a duplicate
        key = shuttle.state_key("AAA", str(video))
        self.assertEqual(state["entries"][key]["status"], "needs_human")
        # second sweep: parked, quiescent (no parse/history calls for it)
        calls_before = len(api.calls)
        counters2 = shuttle.harvest(api, self.env(), state)
        self.assertEqual(counters2["needs_human_parked"], 1)
        self.assertNotIn("needs_human_duplicate", counters2)
        self.assertEqual(len(api.calls), calls_before)

    def test_harvest_pack_incomplete_defers(self):
        video, dest, state = self.make_rescued_file()
        sibling = self.downloads / "rel" / "sibling.mp4"
        sibling.write_bytes(b"z" * 64)  # exists but NOT hardlinked anywhere
        mi = [
            {"path": str(video), "episodes": [], "rejections": [], "downloadId": "AAA"},
            {"path": str(sibling), "episodes": [], "rejections": [], "downloadId": "AAA"},
        ]
        api = FakeApi({
            ("GET", "/api/v3/parse"): {"series": {"id": 5},
                                       "episodes": [{"id": 7, "hasFile": False}],
                                       "parsedEpisodeInfo": {}},
            ("GET", "/api/v3/manualimport"): mi,
        })
        counters = shuttle.harvest(api, self.env(), state)
        self.assertEqual(counters["pack_deferred"], 1)
        self.assertTrue(dest.exists())

    def test_harvest_import_not_confirmed_retries_in_place(self):
        video, dest, state = self.make_rescued_file()
        mi_item = {"path": str(video), "episodes": [], "rejections": [],
                   "downloadId": "AAA", "folderName": "rel", "releaseGroup": "",
                   "quality": {"quality": {"id": 3}}, "languages": [{"id": 1}]}
        api = FakeApi({
            ("GET", "/api/v3/parse"): {"series": {"id": 5},
                                       "episodes": [{"id": 7, "hasFile": False}],
                                       "parsedEpisodeInfo": {}},
            ("GET", "/api/v3/manualimport"): [mi_item],
            ("POST", "/api/v3/command"): {"id": 99},
            ("GET", "/api/v3/command/99"): {"status": "completed"},
            ("GET", "/api/v3/history"): {"records": []},  # never confirms
        })
        counters = shuttle.harvest(api, self.env(), state)
        self.assertEqual(counters["import_failed"], 1)
        self.assertTrue(dest.exists())  # kept for bounded retry, NOT pruned
        key = shuttle.state_key("AAA", str(video))
        self.assertEqual(state["entries"][key]["status"], "fed")
        self.assertEqual(state["entries"][key]["attempts"], 1)

    def test_harvest_ambiguous_parks_after_max_attempts(self):
        video, dest, state = self.make_rescued_file()
        key = shuttle.state_key("AAA", str(video))
        state["entries"][key]["attempts"] = 168
        api = FakeApi({
            ("GET", "/api/v3/parse"): {"series": {"id": 5}, "episodes": []},
        })
        counters = shuttle.harvest(api, self.env(), state)
        self.assertEqual(counters["needs_human_ambiguous"], 1)
        self.assertEqual(state["entries"][key]["status"], "needs_human")
        # subsequent sweeps: standing parked count, zero API calls
        calls_before = len(api.calls)
        counters2 = shuttle.harvest(api, self.env(), state)
        self.assertEqual(counters2["needs_human_parked"], 1)
        self.assertEqual(len(api.calls), calls_before)


class TestOrphansAndReconcile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.scratch = self.root / "scratch"
        for d in ("watch", "work", "failed", "dest"):
            (self.scratch / d).mkdir(parents=True)
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()
        self.state_file = str(self.root / "state.json")

    def tearDown(self):
        self.tmp.cleanup()

    def env(self):
        return {"url": "http://x", "key_file": "", "scratch": str(self.scratch),
                "state_file": self.state_file, "exts": ["mp4"], "max_attempts": 168}

    def orphan_dest(self, name="Site - 2026-01-01 - T [WEBDL-1080p].mp4"):
        src = self.downloads / "gone.mp4"
        src.write_bytes(b"x" * 512)
        dest = self.scratch / "dest" / name
        os.link(src, dest)
        src.unlink()  # original removed out-of-band -> nlink == 1
        return dest

    def test_import_untracked_success(self):
        dest = self.orphan_dest()
        parse_states = iter([
            {"series": {"id": 5}, "episodes": [{"id": 7, "hasFile": False}],
             "parsedEpisodeInfo": {"quality": {"quality": {"id": 3}},
                                   "languages": [{"id": 1}]}},
            {"series": {"id": 5}, "episodes": [{"id": 7, "hasFile": True}]},
        ])
        api = FakeApi({
            ("GET", "/api/v3/parse"): lambda p: next(parse_states),
            ("GET", "/api/v3/manualimport"): [
                {"path": str(dest), "episodes": [], "rejections": [],
                 "quality": {"quality": {"id": 3}}, "languages": [{"id": 1}]}],
            ("POST", "/api/v3/command"): {"id": 100},
            ("GET", "/api/v3/command/100"): {"status": "completed"},
        })
        self.assertEqual(shuttle.import_untracked(api, dest), "imported")
        self.assertFalse(dest.exists())
        cmd = [c for c in api.calls if c[0] == "POST"][0][2]
        self.assertNotIn("downloadId", cmd["files"][0])
        self.assertEqual(cmd["importMode"], "copy")
        self.assertIsNotNone(cmd["files"][0]["quality"])

    def test_import_untracked_duplicate_keeps_pin(self):
        dest = self.orphan_dest()
        api = FakeApi({
            ("GET", "/api/v3/parse"): {"series": {"id": 5},
                                       "episodes": [{"id": 7, "hasFile": True}]},
        })
        self.assertEqual(shuttle.import_untracked(api, dest), "duplicate")
        self.assertTrue(dest.exists())

    def test_orphan_imports_bounded(self):
        dest = self.orphan_dest()
        api = FakeApi({
            ("GET", "/api/v3/parse"): {"series": None, "episodes": []},
        })
        env = self.env()
        env["max_attempts"] = 2
        state = shuttle.load_state(self.state_file)
        counters = Counter()
        shuttle.orphan_imports(api, env, state, counters)
        shuttle.orphan_imports(api, env, state, counters)
        self.assertEqual(counters["untracked_no_match"], 2)
        calls_before = len(api.calls)
        counters3 = Counter()
        shuttle.orphan_imports(api, env, state, counters3)  # past the bound
        self.assertEqual(counters3["needs_human_orphan"], 1)
        self.assertEqual(len(api.calls), calls_before)  # quiescent

    def test_reconcile_reports_pins_and_prunes_state(self):
        # pinned file in failed/ (original gone)
        src = self.downloads / "was.mp4"
        src.write_bytes(b"x" * 2048)
        pin = self.scratch / "failed" / "AAA-deadbeef-was.mp4"
        os.link(src, pin)
        st = src.stat()
        src.unlink()
        state = shuttle.load_state(self.state_file)
        # entry whose original AND links are gone -> pruned
        state["entries"]["GONE:aaaa1111"] = {
            "inode": 999999, "size": 1, "download_id": "GONE",
            "original_path": str(self.downloads / "x.mp4"),
            "link_name": "GONE-aaaa1111-x.mp4", "fed_at": 0, "status": "fed",
            "attempts": 0, "last_refresh": 0}
        # entry matching the pin -> kept
        state["entries"]["AAA:deadbeef"] = {
            "inode": st.st_ino, "size": st.st_size, "download_id": "AAA",
            "original_path": str(self.downloads / "was.mp4"),
            "link_name": "AAA-deadbeef-was.mp4", "fed_at": 0, "status": "fed",
            "attempts": 0, "last_refresh": 0}
        counters = shuttle.reconcile(self.env(), state)
        self.assertEqual(counters["pinned_files"], 1)
        self.assertEqual(counters["pinned_bytes"], 2048)
        self.assertNotIn("GONE:aaaa1111", state["entries"])
        self.assertIn("AAA:deadbeef", state["entries"])

    def test_reconcile_flags_stale_work_and_splits_unsupported(self):
        stale = self.scratch / "work" / "old.mp4"
        stale.write_bytes(b"x")
        old = time.time() - 3 * 86400
        os.utime(stale, (old, old))
        # a fed unsupported-extension pin: counted separately, not awaiting
        src = self.downloads / "clip.wmv"
        src.write_bytes(b"w" * 32)
        link = self.scratch / "watch" / "BBB-cafe0123-clip.wmv"
        os.link(src, link)
        state = shuttle.load_state(self.state_file)
        state["entries"]["BBB:cafe0123"] = {
            "inode": src.stat().st_ino, "size": 32, "download_id": "BBB",
            "original_path": str(src), "link_name": link.name, "fed_at": 0,
            "status": "fed", "attempts": 0, "last_refresh": 0}
        counters = shuttle.reconcile(self.env(), state)
        self.assertEqual(counters["stale_work"], 1)
        self.assertEqual(counters["needs_human_unsupported"], 1)
        self.assertEqual(counters["awaiting_match"], 0)


if __name__ == "__main__":
    unittest.main()
