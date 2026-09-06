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


def canonical_stem(path):
    return Path(path).stem


def site_of(stem):
    return stem.split(" - ", 1)[0]


def normalize_title(s):
    return "".join(ch for ch in s.casefold() if ch.isalnum())


def scan_scratch(scratch):
    """inode -> [paths] across watch/work/failed/dest (videos and sidecars).

    Tolerates entries vanishing mid-scan (the live watchdog moves files
    concurrently)."""
    index = {}
    for sub in SCRATCH_SUBDIRS:
        for p in (Path(scratch) / sub).iterdir():
            try:
                if p.is_file():
                    index.setdefault(p.stat().st_ino, []).append(p)
            except FileNotFoundError:
                continue
    return index


def already_imported(api, download_id):
    resp = api.get("/api/v3/history", {
        "downloadId": download_id, "eventType": 3, "pageSize": 1000})
    records = resp.get("records", resp) if isinstance(resp, dict) else resp
    return {r["episodeId"] for r in records
            if r.get("episodeId") and str(r.get("eventType")) in ("3", "downloadFolderImported")}


def ensure_series(api, site):
    """Return a seriesId for `site`, adding it unmonitored if needed.

    Exact-normalized title match required — never add a guessed series.
    rootFolderPath and qualityProfileId are copied from an existing
    series (self-configuring, per the design doc).
    """
    want = normalize_title(site)
    results = api.get("/api/v3/series/lookup", {"term": site}) or []
    match = next((r for r in results if normalize_title(r.get("title", "")) == want), None)
    if not match:
        return None
    if match.get("id"):
        # Exists in the library but /parse didn't map it (alias gap) —
        # adding again won't help; leave for a human.
        return None
    existing = api.get("/api/v3/series") or []
    if not existing:
        return None
    body = {
        "title": match["title"],
        "tvdbId": match["tvdbId"],
        "qualityProfileId": existing[0]["qualityProfileId"],
        "rootFolderPath": existing[0].get("rootFolderPath") or "",
        "monitored": False,
        "addOptions": {"searchForMissingEpisodes": False},
    }
    if not body["rootFolderPath"]:
        return None
    added = api.post("/api/v3/series", body)
    return added.get("id") if added else None


def pack_complete(items, inode_index):
    """Every video file of the download must have a scratch link before any
    of it may be imported — importing marks the download complete and
    Whisparr removes the torrent WITH DATA (immediately, if paused)."""
    for item in items:
        path = Path(item.get("path", ""))
        if path.suffix.lstrip(".").lower() not in VIDEO_SUPERSET:
            continue
        if not path.exists():
            return False  # inconsistent state; do not risk it
        if path.stat().st_ino not in inode_index:
            return False
    return True


def _confirm_command(api, command_id, timeout=900):
    # Generous: the batched imports are serial multi-GB cross-dataset
    # copies; 120 s would false-fail large batches.
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = api.get(f"/api/v3/command/{command_id}").get("status")
        if status in ("completed", "failed", "aborted"):
            return status
        time.sleep(5)
    return "timeout"


def harvest(api, env, state):
    counters = Counter()
    scratch = env["scratch"]
    dest = Path(scratch) / "dest"
    inode_index = scan_scratch(scratch)
    by_inode = {e["inode"]: (k, e) for k, e in state["entries"].items()
                if e["status"] == "fed"}
    parked_inodes = {e["inode"] for e in state["entries"].values()
                     if e["status"] == "needs_human"}
    # download_id -> list of (dest_path, key, entry, episode_ids, series_id, pei)
    batches = {}
    for dest_path in sorted(p for p in dest.iterdir() if p.is_file()):
        if not is_video(dest_path.name, list(VIDEO_SUPERSET)):
            continue
        try:
            st = dest_path.stat()
        except FileNotFoundError:
            continue
        if st.st_nlink == 1:
            counters["orphan_pending"] += 1  # original gone; orphan pass imports untracked
            continue
        if st.st_ino in parked_inodes:
            counters["needs_human_parked"] += 1  # standing count; quiescent
            continue
        mapped = by_inode.get(st.st_ino)
        if not mapped or mapped[1]["size"] != st.st_size:
            counters["unmapped"] += 1
            print(f"harvest: unmapped dest file: {dest_path.name}", file=sys.stderr)
            continue
        key, entry = mapped
        stem = canonical_stem(dest_path)
        try:
            parse = api.get("/api/v3/parse", {"title": stem}) or {}
            series = parse.get("series")
            episodes = parse.get("episodes") or []
            if not series:
                if ensure_series(api, site_of(stem)):
                    counters["series_added"] += 1  # episodes arrive async; retry next tick
                else:
                    counters["needs_human_series"] += 1
                    print(f"harvest: no confident series for: {stem}", file=sys.stderr)
                continue
            if not episodes:
                entry["attempts"] += 1
                if entry["attempts"] > env["max_attempts"]:
                    entry["status"] = "needs_human"
                    counters["needs_human_ambiguous"] += 1
                    print(f"harvest: parked (no episode after {entry['attempts']} tries): {stem}",
                          file=sys.stderr)
                else:
                    now = int(time.time())
                    if now - entry["last_refresh"] > 86400:
                        api.post("/api/v3/command", {"name": "RefreshSeries",
                                                     "seriesIds": [series["id"]]})
                        entry["last_refresh"] = now
                    counters["awaiting_episode"] += 1
                continue
            episode_ids = [e["id"] for e in episodes]
            if any(e.get("hasFile") for e in episodes):
                if set(episode_ids) & already_imported(api, entry["download_id"]):
                    # Crash-window replay: our own import already landed.
                    dest_path.unlink()
                    entry["status"] = "imported"
                    counters["imported_replay"] += 1
                else:
                    entry["status"] = "needs_human"
                    counters["needs_human_duplicate"] += 1
                    print(f"harvest: duplicate (episode has file), parked: {stem}",
                          file=sys.stderr)
                continue
            pei = parse.get("parsedEpisodeInfo") or {}
            batches.setdefault(entry["download_id"], []).append(
                (dest_path, key, entry, episode_ids, series["id"], pei))
        except urllib.error.HTTPError as err:
            counters["errors"] += 1
            print(f"harvest: {dest_path.name}: HTTP {err.code}", file=sys.stderr)

    for download_id, group in sorted(batches.items()):
        try:
            items_list = manual_import_items(api, download_id)
            if not pack_complete(items_list, inode_index):
                counters["pack_deferred"] += len(group)
                print(f"harvest: pack incomplete, deferring: {download_id}", file=sys.stderr)
                continue
            items = {i["path"]: i for i in items_list}
            files = []
            batch = []
            for dest_path, key, entry, episode_ids, series_id, pei in group:
                item = items.get(entry["original_path"], {})
                quality = item.get("quality") or pei.get("quality")
                languages = item.get("languages") or pei.get("languages")
                if not quality:
                    # Nulls corrupt the import at this build; defer + report.
                    entry["attempts"] += 1
                    counters["quality_missing"] += 1
                    print(f"harvest: no quality for {entry['original_path']}, deferring",
                          file=sys.stderr)
                    continue
                files.append({
                    "path": entry["original_path"],
                    "folderName": item.get("folderName", ""),
                    "seriesId": series_id,
                    "episodeIds": episode_ids,
                    "quality": quality,
                    "languages": languages or [{"id": 1, "name": "English"}],
                    "releaseGroup": item.get("releaseGroup") or "",
                    "downloadId": download_id,
                })
                batch.append((dest_path, key, entry, episode_ids))
            if not files:
                continue
            cmd = api.post("/api/v3/command", {
                "name": "ManualImport", "importMode": "copy", "files": files})
            _confirm_command(api, cmd["id"])
            imported_eps = already_imported(api, download_id)
            for dest_path, key, entry, episode_ids in batch:
                if set(episode_ids) <= imported_eps:
                    dest_path.unlink()
                    entry["status"] = "imported"
                    counters["imported"] += 1
                    print(f"harvest: imported {entry['original_path']} -> {dest_path.name}")
                else:
                    # Keep the dest link + entry: bounded in-place retry
                    # (an unbounded prune-and-refeed would re-POST forever).
                    entry["attempts"] += 1
                    if entry["attempts"] > env["max_attempts"]:
                        entry["status"] = "needs_human"
                        counters["needs_human_import_failed"] += 1
                    else:
                        counters["import_failed"] += 1
                    print(f"harvest: import not confirmed for {entry['original_path']}",
                          file=sys.stderr)
        except urllib.error.HTTPError as err:
            counters["errors"] += 1
            print(f"harvest: {download_id}: HTTP {err.code}", file=sys.stderr)
    return counters


def import_untracked(api, dest_path):
    """Import an orphaned-but-matched dest file (original gone) from its
    scratch path, WITHOUT a downloadId. Frees the pinned bytes on success.
    Confirmation is the episode's hasFile flip (history has no downloadId
    to filter by for untracked imports). Quality comes from the parse
    (spec: "quality from the parse"), item echo as fallback."""
    stem = canonical_stem(dest_path)
    parse = api.get("/api/v3/parse", {"title": stem}) or {}
    series = parse.get("series")
    episodes = parse.get("episodes") or []
    if not series or not episodes:
        return "no_match"
    if any(e.get("hasFile") for e in episodes):
        return "duplicate"  # never auto-unlink a pin; a human decides
    pei = parse.get("parsedEpisodeInfo") or {}
    items = {i["path"]: i for i in
             api.get("/api/v3/manualimport", {
                 "folder": str(dest_path.parent), "filterExistingFiles": "true"}) or []}
    item = items.get(str(dest_path), {})
    quality = pei.get("quality") or item.get("quality")
    languages = pei.get("languages") or item.get("languages")
    if not quality:
        return "no_match"
    cmd = api.post("/api/v3/command", {
        "name": "ManualImport",
        "importMode": "copy",
        "files": [{
            "path": str(dest_path),
            "folderName": "",
            "seriesId": series["id"],
            "episodeIds": [e["id"] for e in episodes],
            "quality": quality,
            "languages": languages or [{"id": 1, "name": "English"}],
            "releaseGroup": "",
        }],
    })
    _confirm_command(api, cmd["id"])
    parse2 = api.get("/api/v3/parse", {"title": stem}) or {}
    episodes2 = parse2.get("episodes") or []
    if episodes2 and all(e.get("hasFile") for e in episodes2):
        dest_path.unlink()
        return "imported"
    return "no_match"


def orphan_imports(api, env, state, counters):
    dest = Path(env["scratch"]) / "dest"
    by_inode = {e["inode"]: k for k, e in state["entries"].items()}
    for dest_path in sorted(p for p in dest.iterdir() if p.is_file()):
        if not is_video(dest_path.name, list(VIDEO_SUPERSET)):
            continue
        try:
            st = dest_path.stat()
        except FileNotFoundError:
            continue
        if st.st_nlink != 1:
            continue
        attempts = state["orphan_attempts"].get(str(st.st_ino), 0)
        if attempts >= env["max_attempts"]:
            counters["needs_human_orphan"] += 1  # standing count; quiescent
            continue
        try:
            outcome = import_untracked(api, dest_path)
        except urllib.error.HTTPError as err:
            counters["errors"] += 1
            print(f"orphan: {dest_path.name}: HTTP {err.code}", file=sys.stderr)
            continue
        counters[f"untracked_{outcome}"] += 1
        if outcome == "imported":
            state["orphan_attempts"].pop(str(st.st_ino), None)
            key = by_inode.get(st.st_ino)
            if key:
                state["entries"][key]["status"] = "imported"
            print(f"orphan: imported untracked -> {dest_path.name}")
        else:
            state["orphan_attempts"][str(st.st_ino)] = attempts + 1
            print(f"orphan: {outcome}: {dest_path.name}", file=sys.stderr)


def reconcile(env, state):
    """Tie link/state lifecycles to reality. Never deletes data: pins are
    reported, only ever removed by a human."""
    counters = Counter()
    scratch = env["scratch"]
    inode_index = scan_scratch(scratch)
    now = time.time()
    for sub in SCRATCH_SUBDIRS:
        for p in (Path(scratch) / sub).iterdir():
            try:
                if not p.is_file() or not is_video(p.name, list(VIDEO_SUPERSET)):
                    continue
                st = p.stat()
            except FileNotFoundError:
                continue
            if st.st_nlink == 1:
                counters["pinned_files"] += 1
                counters["pinned_bytes"] += st.st_size
                print(f"reconcile: pin ({sub}, {st.st_size} bytes): {p.name}",
                      file=sys.stderr)
            if sub == "work" and now - st.st_mtime > 86400:
                counters["stale_work"] += 1
                print(f"reconcile: stale in work/ (>1 day): {p.name}", file=sys.stderr)
    for key in sorted(state["entries"]):
        entry = state["entries"][key]
        original_gone = not Path(entry["original_path"]).exists()
        no_links = entry["inode"] not in inode_index
        if original_gone and no_links:
            # Resolved out-of-band (imported+removed, or user-deleted).
            del state["entries"][key]
            counters["state_pruned"] += 1
    # awaiting-match = fed, namer-supported, not yet in dest;
    # fed-but-unsupported entries are a standing needs-human count.
    dest_inodes = set()
    for p in (Path(scratch) / "dest").iterdir():
        try:
            if p.is_file():
                dest_inodes.add(p.stat().st_ino)
        except FileNotFoundError:
            continue
    for e in state["entries"].values():
        if e["status"] != "fed" or e["inode"] in dest_inodes:
            continue
        if is_video(e["original_path"], env["exts"]):
            counters["awaiting_match"] += 1
        else:
            counters["needs_human_unsupported"] += 1
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
        counters += harvest(api, env, state)
        orphan_imports(api, env, state, counters)
        counters += reconcile(env, state)
    except (urllib.error.URLError, OSError) as err:
        print(f"shuttle: aborted: {err}", file=sys.stderr)
        rc = 1
    save_state(env["state_file"], state)
    print("shuttle:", ", ".join(f"{k}={v}" for k, v in sorted(counters.items())) or "nothing to do")
    return rc


if __name__ == "__main__":
    sys.exit(main())
