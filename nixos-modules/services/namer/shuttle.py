"""Whisparr <-> namer shuttle.

Feeds Whisparr's import-blocked download files into namer's watch dir as
zero-byte hardlinks, harvests namer's canonical names from dest/, and
drives Whisparr's manual-import API (download-associated) so completed-
download handling keeps owning torrent cleanup. Pure stdlib.

Design doc: docs/plans/active/whisparr-namer-import-rescue.md
Invariants (do not break):
  - NEVER write file content under the downloads filesystem: link/stat/
    unlink/rename only.
  - importMode is always "copy" ("auto" MOVES paused torrents' files).
  - Import confirmation is a state observation (history eventType=3),
    never command completion.
  - NEVER pass seriesId to GET /api/v3/manualimport: the controller
    short-circuits into a series-LIBRARY-folder listing (media dataset)
    and ignores downloadId entirely.
"""
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

SCRATCH_SUBDIRS = ("watch", "work", "failed", "dest")

# Extensions we recognize as video for pinning purposes even when namer's
# configured target_extensions (env exts) is narrower. Keep a superset.
VIDEO_SUPERSET = {
    "mp4", "mkv", "avi", "mov", "flv", "wmv", "m4v", "ts", "webm", "mpg",
    "mpeg", "iso", "m2ts", "vob", "divx", "xvid", "rmvb", "asf", "3gp",
}


class WhisparrApi:
    def __init__(self, base_url, api_key):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key

    def _request(self, method, path, params=None, body=None):
        url = self.base_url + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("X-Api-Key", self.api_key)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = resp.read()
        return json.loads(payload) if payload else None

    def get(self, path, params=None):
        return self._request("GET", path, params=params)

    def post(self, path, body):
        return self._request("POST", path, body=body)


def load_env():
    key_file = os.environ["WHISPARR_API_KEY_FILE"]
    return {
        "url": os.environ["WHISPARR_URL"],
        "key_file": key_file,
        "scratch": os.environ["SCRATCH_DIR"],
        "state_file": os.environ["STATE_FILE"],
        "exts": [e.strip().lower() for e in os.environ["TARGET_EXTENSIONS"].split(",") if e.strip()],
        "max_attempts": int(os.environ.get("AMBIGUITY_MAX_ATTEMPTS", "168")),
    }


def load_state(path):
    try:
        with open(path) as f:
            state = json.load(f)
    except FileNotFoundError:
        state = {"version": 1, "entries": {}}
    state.setdefault("orphan_attempts", {})
    return state


def save_state(path, state):
    tmp = path + ".new"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def is_video(name, exts):
    suffix = Path(name).suffix.lstrip(".").lower()
    return suffix in exts


def path_hash(path):
    return hashlib.sha1(str(path).encode()).hexdigest()[:8]


def state_key(download_id, path):
    return f"{download_id}:{path_hash(path)}"


def link_name(download_id, path):
    # The hash disambiguates same-basename files within one pack
    # (cd1/scene.mp4 vs cd2/scene.mp4).
    return f"{download_id}-{path_hash(path)}-{Path(path).name}"


def list_import_blocked(api):
    """downloadIds of completed, import-blocked queue rows.

    includeUnknownSeriesItems=true is required: unknown-series rows (the
    worst-stuck items) are hidden by default. This build has no server-side
    status filter; one row per episode -> dedupe by downloadId.
    """
    blocked = set()
    page = 1
    while True:
        resp = api.get("/api/v3/queue", {
            "page": page, "pageSize": 1000, "includeUnknownSeriesItems": "true"})
        records = resp.get("records", [])
        for r in records:
            did = r.get("downloadId")
            if not did:
                continue
            if r.get("status") != "completed":
                continue  # still downloading; manualimport would 500
            if r.get("trackedDownloadStatus") != "warning":
                continue
            if r.get("trackedDownloadState") not in ("importPending", "downloading"):
                continue
            blocked.add(did)
        if page * 1000 >= resp.get("totalRecords", 0) or not records:
            return blocked
        page += 1


def manual_import_items(api, download_id):
    # NEVER add seriesId here: it flips the endpoint into a series-library
    # listing that ignores downloadId (see module docstring).
    return api.get("/api/v3/manualimport", {
        "downloadId": download_id, "filterExistingFiles": "true"}) or []


def feedable(item):
    """A file namer should see: no episodes assigned, or rejected.

    The no-episodes clause also covers the >100-file unknown-series
    degraded shape (downloadId=null, no rejections, Unknown quality).
    """
    return not item.get("episodes") or bool(item.get("rejections"))


def feed(api, env, state):
    counters = Counter()
    watch = Path(env["scratch"]) / "watch"
    for download_id in sorted(list_import_blocked(api)):
        try:
            items = manual_import_items(api, download_id)
        except urllib.error.HTTPError as err:
            counters["errors"] += 1
            print(f"feed: manualimport {download_id}: HTTP {err.code}", file=sys.stderr)
            continue
        for item in items:
            path = item.get("path")
            if not path or not feedable(item):
                continue
            key = state_key(download_id, path)
            if key in state["entries"]:
                continue
            suffix = Path(path).suffix.lstrip(".").lower()
            if suffix not in VIDEO_SUPERSET:
                continue  # nfo/jpg/txt sidecars are Whisparr's problem
            source = Path(path)
            if not source.exists():
                counters["missing_on_disk"] += 1
                print(f"feed: {download_id}: missing on disk: {path}", file=sys.stderr)
                continue
            target = watch / link_name(download_id, path)
            try:
                os.link(source, target)
            except FileExistsError:
                pass  # already fed; state was lost -> self-heal the entry
            except PermissionError:
                counters["eperm"] += 1
                print(f"feed: EPERM hardlinking {path} (fs.protected_hardlinks needs "
                      f"g+w on the source; see design doc)", file=sys.stderr)
                continue
            if suffix not in env["exts"]:
                # namer will never process this extension, but the link
                # still pins the file (pack completeness / data safety).
                counters["unsupported_extension"] += 1
            st = source.stat()
            state["entries"][key] = {
                "inode": st.st_ino,
                "size": st.st_size,
                "download_id": download_id,
                "original_path": str(source),
                "link_name": target.name,
                "fed_at": int(time.time()),
                "status": "fed",
                "attempts": 0,
                "last_refresh": 0,
            }
            counters["fed"] += 1
    return counters


def main():
    env = load_env()
    with open(env["key_file"]) as f:
        api_key = f.read().strip()
    api = WhisparrApi(env["url"], api_key)
    state = load_state(env["state_file"])
    counters = Counter()
    rc = 0
    try:
        counters += feed(api, env, state)
    except (urllib.error.URLError, OSError) as err:
        print(f"shuttle: aborted: {err}", file=sys.stderr)
        rc = 1
    save_state(env["state_file"], state)
    print("shuttle:", ", ".join(f"{k}={v}" for k, v in sorted(counters.items())) or "nothing to do")
    return rc


if __name__ == "__main__":
    sys.exit(main())
