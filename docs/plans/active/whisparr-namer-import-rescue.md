# Whisparr import rescue via namer (phash) — design

Status: design approved and adversarially reviewed (2026-09-05),
implementation not started. Companion to the seeding-lifecycle work
(commits `67fdedc`, `29ac595`): that made torrents seed 14 days, pause,
and get removed by Whisparr once imported — this design rescues the
files Whisparr cannot import on its own so that lifecycle can finish
the job.

Review round: four independent adversarial reviews (namer source,
Whisparr source at the deployed commit, systems/race analysis, repo
conventions) ran against the first draft; every surviving finding is
folded in below. Whisparr behavior was verified at commit `437da72` —
proven to be the source of the deployed 2.0.0.2151 (the servarr
nightly channel nixpkgs pulls from is frozen at Jan 2026). Re-verify
the "Verified at source" items whenever nixpkgs bumps Whisparr.

## Problem

Whisparr V2 (Sonarr fork, 2.0.0.2151) matches downloads to scenes by
parsing the release name (`Site.YYYY.MM.DD.Title...`). A large share of
grabbed releases have unparseable names, fail with "Invalid season or
episode", and pile up in Activity → Queue as "Downloaded - Waiting to
Import" (~103 items at design time). Manual import through Whisparr's
UI is high-friction (per-file identification; >100-files-per-folder
degradation; series-folder crash).

Consequence beyond toil: a torrent whose download is never imported is
never removed by `removeCompletedDownloads`, so after the 14-day seed
cap it sits paused in `/tank0/downloads/whisparr` holding its space
forever.

namer (ThePornDatabase/namer, packaged in this repo as `pkgs.namer`)
identifies files by perceptual hash against TPDb's phash index — the
same content, regardless of how mangled the release name is. Verified
end-to-end on a real stuck file: phash lookup returned the correct
scene and a canonical, Whisparr-parseable name.

## Approach (chosen: watchdog-centric, Whisparr executes)

Two units glued by hardlinks and Whisparr's own APIs:

- **namer watchdog + web UI** (always on) — does all matching, both
  automatic (phash) and manual (web UI on its failed queue).
- **shuttle** (hourly timer) — feeds Whisparr's import-blocked files
  into namer as zero-byte hardlinks, harvests namer's canonical names,
  and asks Whisparr to import the *original* file via its manual-import
  API with the downloadId attached. Every sweep ends with a
  reconciliation pass that ties scratch-link and state lifecycles to
  the original files' existence.

Ownership stays singular:

| Concern                                         | Owner                                                  |
| ----------------------------------------------- | ------------------------------------------------------ |
| Identification (auto + manual)                  | namer                                                  |
| Naming authority, library copy, catalog         | Whisparr                                               |
| Download/torrent lifecycle & space reclaim      | Whisparr `removeCompletedDownloads` + qBt 14-day pause |
| Scratch-link + state lifecycle, orphan recovery | shuttle reconciliation                                 |
| Seeding                                         | qBittorrent, never touched                             |

Rejected alternatives:

- *CLI-sweep matcher + watchdog only for manual fixes* — two matcher
  invocation paths, two harvest sources, watchdog's daily retry fights
  the sweep over the same files. More glue, no capability gain.
- *namer imports directly into the library, Whisparr rescans* — least
  glue, but rescan-imports carry no download association, so
  `removeCompletedDownloads` never fires and paused torrents accumulate
  forever; namer would also become a second naming authority whose
  template must mirror Whisparr's indefinitely.

## Verified constraints

Filesystem / seeding:

- `/tank0/downloads` and `/tank0/media/*` are separate ZFS datasets
  (disko.nix): every import is a full copy; cross-dataset hardlinks
  impossible. Hardlinks *within* the downloads dataset are free — the
  mechanism this design is built on.
- Seeding files must not be moved or renamed (their own directory
  entry) and their content must not be mutated until the torrent
  pauses. Renaming a *second* hardlink to the same inode is a pure
  directory-entry operation and is safe. Content AND inode-metadata
  mutation through a hardlink (mp4 tagging, chmod/chown) is NOT safe —
  shared inode.
- `tank0/downloads` has no snapshots today (verified: no
  sanoid/autosnapshot anywhere in the repo), so deletion = reclaim.
  The pending backup plan (`scheelite-backup-options.md`) MUST exclude
  `tank0/downloads` from any snapshot policy or removals stop
  reclaiming and orphan cleanup gets snapshot-pinned.

namer (verified in v1.19.20 source; **`namer.cfg.default` — not the
`configuration.py` dataclass — defines the effective defaults**, and
several differ):

- `namer suggest` does not phash — `metadataapi.main` calls
  `match(parsed_file, config)` with no phash argument
  (`namer/metadataapi.py:591-638`). Name-parse only; useless here.
- `namer rename`/watchdog is the only phash-matching entry point
  (`namer/namer.py:187-193`), and it renames its target — hence the
  hardlink trick.
- Every file movement in the watchdog pipeline is `shutil.move` =
  same-fs rename, never a copy (watch→work `command.py:85,89`;
  work→dest `command.py:241`; work→failed `namer.py:213-216`;
  failed→watch retry `watchdog.py:95-97`; web-UI failed→work
  `api.py:90-95`). Zero-byte and inode-mapping claims hold.
- With the pins below, no code path writes video content: tagging is
  gated at `namer.py:119`, posters/nfo/trailer gated separately. The
  one write namer does perform on failure is a small
  `<stem>_namer.json.gz` sidecar next to the failed file
  (`write_namer_failed_log`, effective default true) — a separate tiny
  inode, harmless to seeding, and the web UI consumes it for its
  match% columns. Keep it.
- **Effective-default traps** (all pinned in the config we render):
  - `update_permissions_ownership = True` in namer.cfg.default:86 —
    unpinned, namer `lchown`s the qbt-owned shared inode →
    PermissionError → file strands in `work/`. The `false` pin is
    load-bearing.
  - `retry_time =` (empty) in namer.cfg.default:280 — the empty string
    defeats the "random 3am" fallback (dead code); **no daily retry
    ever runs unless we pin a value**.
  - `web = False` in namer.cfg.default:283 — the manual-match surface
    never starts unless pinned true.
  - The watchdog's dest naming key is `new_relative_path_name`
    (namer.cfg.default:258), NOT `inplace_name`, and its default
    contains a `{full_site}/` subdirectory — must be pinned flat.
  - `target_extensions = mp4,mkv,avi,mov,flv` — a fed `.wmv`/`.ts`/
    `.webm` is silently ignored (never moved, invisible in the web
    UI); the shuttle must know the list.
- Files move watch→work at **detection** time (startup scan included,
  `watchdog.py:278-288`), and namer refuses to start if `work/` holds
  more than 1 MiB (`configuration_utils.py:84-88` → `sys.exit(-1)`,
  `watchdog.py:340-341`). During a burst the whole backlog sits in
  `work/` → any restart would crash-loop. Mitigation: `ExecStartPre`
  renames `work/*` back into `watch/` (safe: state is inode-keyed, the
  startup scan re-ingests, and the phash cache is keyed
  (name,size,mtime) so nothing recomputes).
- Pre-existing `watch/` files ARE processed at startup (polling
  observer, no inotify dependency) — files fed while namer is down are
  picked up. `NAMER_CONFIG` env var is the ONLY config mechanism for
  `namer watchdog` (no `-c` flag on that subcommand). namer creates
  none of the four dirs (verify fails if missing) — tmpfiles are
  mandatory. All state (phash DB, requests cache) lands under
  `database_path`, default CWD-relative — must be pinned.
- dest collisions get a ` (N)` suffix before the extension, never an
  overwrite; nothing deletes dest files under the pinned config
  (`preserve_duplicates = true` — if ever flipped, namer silently
  unlinks losing duplicates; pin it).
- namer exits nonzero at startup if TPDb is unreachable
  (`watchdog.py:343-345`) — unit needs `Restart=on-failure` +
  `RestartSec`.
- Phash match safety: the guards are exact distance-0 matching plus
  multi-candidate nullification (`comparison_results.py:389-403`);
  duration only annotates, it does not gate.

Whisparr (verified at deployed commit `437da72`; clone kept at
`~/.claude/jobs/cae170ba/tmp/investigate/whisparr` during review):

- Manual import: `GET /api/v3/manualimport?downloadId=X&filterExistingFiles=true`
  returns per-file items with rejections; execution is
  `POST /api/v3/command` with `name=ManualImport` (NOT POST
  /manualimport — that's reprocess). Per-file `quality` and
  `languages` are applied verbatim and effectively mandatory — omitted
  values import broken records at this build. Echo them from the GET
  item (or `/parse`'s parsedEpisodeInfo).
- **A download is marked Imported when imported-episode-count ≥
  `Math.Max(1, RemoteEpisode?.Episodes?.Count ?? 1)`**
  (`ManualImportService.cs:549-558`) — for single-scene grabs that is
  1, so the FIRST imported file completes the download, and
  `DownloadEventHub` immediately removes the torrent **with data**
  (`RemoveItem(item, true)`) if it's already paused-at-limit
  (`CanBeRemoved = pausedUP/stoppedUP && HasReachedSeedLimit`,
  `QBittorrent.cs:238`). Still-seeding torrents are removed later by
  `DownloadProcessingService` on refresh. Partial-pack policy below
  exists because of this.
- Manual import **bypasses every import specification**
  (`ManualImportService.cs:508` constructs the decision with no spec
  evaluation) and runs upgrade semantics — an episode that already has
  a file gets it replaced. The shuttle's hasFile guard is the ONLY
  protection against replacing library content.
- `importMode` is load-bearing: `copy` never moves; `auto` resolves to
  MOVE for a paused torrent (`copyOnly = item != null && !item.CanMoveFiles` and paused-at-limit sets CanMoveFiles=true) —
  which would relocate the seeding file. Always `copy`. Copy mode also
  keeps the post-import folder-delete branch disarmed (the unparseable
  original remaining in the folder makes `ShouldDeleteFolder` false).
- Queue: `GET /api/v3/queue` hides unknown-series rows unless
  `includeUnknownSeriesItems=true` — and those are exactly the
  worst-stuck items. No server-side status filter at this build;
  filter client-side. One row PER EPISODE → dedupe by downloadId.
- Two distinct stuck shapes must both be fed:
  `trackedDownloadState=importPending` (parse produced no episode) and
  `trackedDownloadState=downloading` with `status=completed` +
  `trackedDownloadStatus=warning` (series unresolvable — these never
  reach ImportPending on their own).
- `GET /manualimport?downloadId` throws HTTP 500 (NRE) for
  still-downloading items — only query items whose queue
  `status=completed`.
- \>100 video files in an unknown-series folder: the GET degrades to a
  directory listing with `downloadId=null`, `rejections=[]`, and
  Quality/Language `Unknown`. **Never pass `seriesId` to this GET**: the
  controller short-circuits on `seriesId.HasValue` into a
  series-LIBRARY-folder listing (`ManualImportController.cs:28-31` →
  `GetMediaFiles(int seriesId, ...)` scanning `series.Path` on the
  media dataset) and ignores `downloadId` entirely — feeding library
  files instead of the download's. The degraded shape is already
  covered by treating "no episodes assigned" (not just "has
  rejections") as feedable, and its Unknown quality is guarded by the
  harvest's parse-fallback for the quality echo.
- Confirmation: command completion ≠ import success (failed
  ImportResults still complete the command). Confirm via
  `GET /api/v3/history?downloadId=X&eventType=3`
  (DownloadFolderImported).
- `/parse` handles `Site - YYYY-MM-DD - Title [WEBDL-1080p]` (daily
  regex accepts " - " separators; series matched via title, aliases,
  slug) and returns `episodes[].hasFile`. Caveat: multiple scenes on
  one air date need an unambiguous title match; ambiguity returns
  series + empty episodes — indistinguishable from
  episode-not-in-metadata, so the retry loop must be bounded (park +
  report after N attempts).
- Series add: `POST /api/v3/series` requires title, `tvdbId` (from
  `/series/lookup?term=`), `qualityProfileId`, `rootFolderPath`.
  Episodes arrive asynchronously via an auto-queued RefreshSeries —
  the harvest's retry-next-tick absorbs the delay.
- **Retroactivity confirmed**: every refresh re-tracks all category
  items; imported-months-ago torrents get `State=Imported` restored
  from download history and are removed once paused-at-limit. The
  ~463-torrent historical backlog will clean itself as torrents hit
  the 14-day pause — no one-time bulk removal needed.

Repo (verified):

- Auto-import: `nixos-modules/default.nix:30-33` +
  `nixos-modules/services/module.nix:18-26` import every
  `services/<dir>/module.nix` — a new module needs no manual wiring.
- sops-nix supports `sops.secrets.<name>.key` aliasing — a second
  secret entry can reuse the single `whisparr/api-key` yaml value with
  a different owner. First use of the pattern in this repo.
- Caddy snippets `(acme_resolvers)` and `(forward_auth_kanidm)` exist;
  oauth2-proxy whitelists all `*.<lanDomain>` subdomains and AdGuard
  wildcards resolve them — a new vhost needs zero extra wiring.
- qBittorrent: scheelite `downloadsDir = /tank0/downloads`,
  autoCategories → `/tank0/downloads/whisparr` (as assumed). No UMask
  is set anywhere (upstream module has no knob; qBt's WebUI API has no
  umask field) → files are 0644, group `media` read-only. With
  `fs.protected_hardlinks=1` (kernel/systemd default; repo doesn't
  override) a non-owner needs r+w to hardlink → the `namer` user
  CANNOT hardlink today's files. Fix mechanism:
  `systemd.services.qbittorrent.serviceConfig.UMask = "0002"` for new
  files PLUS a one-time `chmod -R g+w /tank0/downloads/whisparr`
  (inode metadata only — safe for seeding) for the existing backlog.
- `/tank0/services/<svc>` is one-ZFS-dataset-per-service
  (disko.nix:429-514, `mountpoint = "legacy"`), datasets created
  manually on the pool as a documented prerequisite. namer needs a
  `tank0/services/namer` dataset: disko.nix entry + manual
  `zfs create` before deploy.
- Module-default convention: portable `/var/lib/<svc>` defaults in the
  module; tank paths set host-side on scheelite. Sibling user idiom:
  `isSystemUser` + dedicated primary group + `extraGroups = [ "media" ]`.
  Homepage tiles are a hardcoded `knownTiles` list — a namer tile is a
  one-line addition (in scope).
- The staged `package-sets/top-level/namer/package.nix` still carries
  `patches = [ ./jav-auto-lookup.patch ]` — commit 1 edits the file
  (drop the line, delete the patch), not commit-as-is. New module dirs
  must be `git add`ed before nix can evaluate them.

Scope of matching:

- Western/studio content only: TPDb has phash coverage there. JAV has
  none (`has_hashes:0` on `/jav`) and namer's parser splits JAV codes —
  JAV stays on Whisparr's native JAV tab. OnlyFans rips are mostly
  fingerprint-less too and will form the bulk of the residual manual
  set.

## Decisions (user-approved 2026-09-05)

- Ongoing hourly systemd timer, not an on-demand tool. The ~103
  backlog is just the first sweep.
- A scene identified as belonging to a site missing from Whisparr's
  library → auto-add the site **unmonitored**, then import.
- Files namer can't identify either: stay visible in Whisparr's queue
  **and** appear in namer's web UI (`failed/`) for manual matching;
  every sweep logs a summary. No auto-purge.
- Skip-and-report if the target episode already has a file — never
  silently replace library content (and per the review, this guard is
  the only one: manual import bypasses all specs).
- **Partial packs: import matched files immediately; pin unmatched
  siblings.** Importing any file of a pack lets Whisparr delete the
  whole torrent, so: (a) a pack's files are only imported once EVERY
  video file of that downloadId has a scratch hardlink (nothing can be
  destroyed unlinked); (b) after removal, unmatched siblings survive
  as their scratch links — intentional pins, reported with sizes by
  reconciliation; (c) a pinned file matched later (web UI / daily
  retry) is imported **untracked** (folder-mode manual import from the
  scratch path, no downloadId) and then unlinked, freeing the bytes.
- `pkgs.namer` gets committed as part of this work (first commit of
  the series), with the exploratory `jav-auto-lookup.patch` dropped.

## Data flow — life of a stuck file

On the downloads dataset there is only ever one copy of the data (one
inode); the pipeline manipulates directory entries. The only real copy
is Whisparr's import into the library.

1. **Download & seed** — qBt writes
   `/tank0/downloads/whisparr/<release>/file.mp4` (inode X), seeds.
   Whisparr can't parse the name → queue item stuck.
1. **Feed** (shuttle) — hardlink into `watch/` as
   `<downloadId>-<pathhash8>-<basename>` (same dataset, zero bytes; the
   downloadId prefix makes failed/-dir entries self-describing, and the
   8-char path hash disambiguates packs carrying the same basename in
   different subfolders — `cd1/scene.mp4` vs `cd2/scene.mp4`). Record
   `{inode, size, downloadId, originalPath, fedAt}` in the state file.
   qBt seeds on, oblivious.
1. **Match** (namer watchdog) — watch → work → phash → TPDb.
   Match: canonical-named entry lands in `dest/` (still inode X).
   No match: entry lands in `failed/` (+ a small json.gz sidecar the
   web UI uses), visible in the web UI; a manual match there also ends
   in `dest/`; the pinned `retry_time` re-feeds `failed/` nightly.
   Content is never written (pins below).
1. **Harvest** (shuttle) — for each `dest/` file: stat → inode (+size
   cross-check) → state → `{downloadId, originalPath}`; Whisparr
   `/parse` on the canonical name → series + episode (auto-adding a
   missing site unmonitored first if needed); then ONE ManualImport
   command per downloadId batching ALL its matched files, `importMode: copy`, quality/languages echoed from the GET. Whisparr makes the
   one real copy into `/tank0/media/adult/...` (inode Y), named by
   *its* naming config, catalogued. Import confirmed via the history
   API, then the `dest/` link is unlinked and the state entry closed.
   Jellyfin/Stash see inode Y immediately.
1. **Cleanup** — the existing lifecycle finishes: on import, Whisparr
   removes the torrent **with data** immediately if it is already
   paused at the seed limit, or at the 14-day pause otherwise → inode
   X's last download-side link gone → space reclaimed (any remaining
   scratch links are intentional pins, tracked by reconciliation).
1. **Reconcile** (shuttle, every sweep) — scratch-link and state
   lifecycles are tied to reality; see the algorithm below.

```
downloads dataset (inode X, one data copy)          media dataset
qbt: whisparr/<release>/file.mp4  ── seeds ──┐
      │ ln (0 bytes)                         │
.namer/watch → work → dest (canonical name)  │      /tank0/media/adult/Site/
      │            ↘ failed ⇄ web UI/retry   │        Site - date - title.mp4
      └ harvest: parse + manual-import ──────┴──copy──► (inode Y, Whisparr-named)
        then rm dest hardlink
import ⇒ Whisparr removes torrent+data (now, if paused; else at 14d pause)
      → inode X freed unless a scratch link intentionally pins it
```

Deletion ownership:

| Artifact                           | Deleted by                                                                     | When                                                                                                                                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `dest/` hardlink                   | shuttle                                                                        | after confirmed import (history event for tracked; hasFile flip for untracked)                                                                                                       |
| `watch/`/`work/`/`failed/` entries | namer watchdog (processing/retry); shuttle reconciliation reports what remains | continuous                                                                                                                                                                           |
| Seeding original (the real bytes)  | Whisparr via qBt                                                               | on import if already paused-at-limit, else at the 14-day pause                                                                                                                       |
| Library copy                       | nobody                                                                         | permanent                                                                                                                                                                            |
| Never-matched files                | nobody (by design)                                                             | scratch link costs 0 bytes while the original exists; after any out-of-band removal it becomes an intentional pin holding the bytes — reconciliation reports every pin with its size |

## Components

New module `nixos-modules/services/namer/module.nix` (auto-imported),
namespace `theonecfg.services.namer`, owning two units. Both secrets
(`namer/tpdb-token`, the `whisparr/api-key` alias) are declared in the
module; the scheelite commit only populates `secrets/scheelite.yaml`.

`namer.service` — watchdog + web UI:

- `ExecStart = ${pkgs.namer}/bin/namer watchdog`, `NAMER_CONFIG`
  pointing at a sops-templated config (TPDb token placeholder; env var
  is the only config mechanism for watchdog mode).
- `ExecStartPre` (as the service user): rename any `work/*` entries
  back into `watch/` — mandatory crash/restart recovery, without which
  namer refuses to start when `work/` is non-empty.
- `Restart = on-failure` + `RestartSec` (namer exits nonzero when TPDb
  is unreachable at startup).
- User `namer` (`isSystemUser`, primary group `namer`,
  `extraGroups = [ "media" ]`), matching sibling idiom.
- Scratch dirs `${scratchDir}/{watch,work,failed,dest}` via tmpfiles
  (`2775 namer media`); scratch MUST live on the downloads dataset —
  the module derives its default from
  `theonecfg.services.qbittorrent.downloadsDir`.
- Data dir (phash DB, requests cache, rendered-config adjacent state)
  defaults to `/var/lib/namer`; scheelite overrides to
  `/tank0/services/namer` (new ZFS dataset — see outline).
- Web UI binds `127.0.0.1:${port}`; Caddy vhost `namer.<lanDomain>`
  with `import acme_resolvers` + `import forward_auth_kanidm`; one
  homepage `knownTiles` entry.
- `RequiresMountsFor` downloads + data dir; hardening cloned from the
  sonarr-anime block, plus `ProtectSystem = "strict"` with
  `ReadWritePaths` = scratch + data dir.

`whisparr-namer-shuttle.service` + `.timer`:

- Oneshot; `OnCalendar=hourly`, `RandomizedDelaySec=5m`,
  `Persistent=true`. Gated on both namer and whisparr being enabled.
  systemd guarantees no overlapping runs; the restart-mid-run case is
  what confirmation-by-history and reconciliation absorb.
- Runs as `namer`; Whisparr API key via
  `sops.secrets."whisparr/api-key-namer" = { key = "whisparr/api-key"; owner = "namer"; }` (supported by the pinned sops-nix; no second
  yaml entry).
- Implementation language: Python stdlib (`writers.writePython3Bin`,
  which flake8-checks the script at build time). The glue is stateful,
  multi-endpoint, and branchy — wrong shape for the repo's shell+jq
  declarative-push idiom, which stays as-is for the push services.
- Talks only to Whisparr's API — no qBt API needed.

## Option surface

```nix
theonecfg.services.namer = {
  enable = mkEnableOption ...;
  scratchDir = ...;     # default "${qbittorrent.downloadsDir}/.namer"
  dataDir    = ...;     # default "/var/lib/namer"; scheelite: /tank0/services/namer
  port       = 6980;
  domain     = "namer.${lanDomain}";
  settings   = { ... }; # freeform INI overlay (note: empty values are
                        # ignored by namer's parser — you cannot clear
                        # a nonempty default, only replace it)
  shuttle.enable   = true;   # gated on whisparr.enable
  shuttle.interval = "hourly";
};
```

Pinned namer.cfg values (keys verified against `namer.cfg.default`;
remember: that file, not the dataclass, is the effective-defaults
layer):

| Setting                              | Value                                                           | Why                                                                                                                                                                                             |
| ------------------------------------ | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `enabled_tagging` / `enabled_poster` | false                                                           | tagging writes the shared inode → corrupts the seeding copy (effective defaults are false; pinned so a flip can't hurt)                                                                         |
| `update_permissions_ownership`       | false                                                           | **effective default is TRUE** — would lchown/chmod the shared inode, PermissionError, strand in work/. Load-bearing pin                                                                         |
| `min_file_size`                      | 0                                                               | default 300 MiB would skip short scenes                                                                                                                                                         |
| `search_phash`                       | true (default) + Go videohashes (`use_alt_phash_tool=false`)    | Stash-compatible hasher; serial single worker = natural TPDb politeness (there is no rate limiter)                                                                                              |
| `use_database`                       | true                                                            | phash cache keyed (name,size,mtime) — survives retry cycles and the ExecStartPre work/-sweep                                                                                                    |
| `database_path`                      | `${dataDir}`                                                    | default is CWD-relative                                                                                                                                                                         |
| `new_relative_path_name`             | flat `{full_site} - {date} - {name} [WEBDL-{resolution}].{ext}` | the watchdog's dest naming key (NOT `inplace_name`); default contains a `{full_site}/` subdir which would break the flat harvest scan. Whisparr-parseable shape (proven live)                   |
| `retry_time`                         | `03:17`                                                         | **effective default is empty = no retry ever**; pinning restores the free TPDb-index-growth retries and parks the daily failed→watch churn in a dead hour (avoids racing a human in the web UI) |
| `web` / `host` / `port`              | true / `127.0.0.1` / `${port}`                                  | web is OFF by effective default; the manual-match pillar needs it                                                                                                                               |
| `preserve_duplicates`                | true                                                            | if false, namer silently unlinks losing duplicates in dest                                                                                                                                      |
| `target_extensions`                  | `mp4,mkv,avi,mov,flv,wmv,m4v,ts,webm,mpg,mpeg`                  | superset of the default; namer silently ignores anything outside the list                                                                                                                       |
| `write_namer_log`                    | false                                                           | success-side artifact litter off                                                                                                                                                                |
| `write_namer_failed_log`             | true (default)                                                  | the failed-side json.gz sidecars power the web UI's match columns; retry/success/delete paths clean them up                                                                                     |
| `convert_container_to`               | MUST stay unset                                                 | re-muxes into a NEW inode: a full data copy on the downloads dataset and a broken inode mapping                                                                                                 |

Secrets: new `namer/tpdb-token` in `secrets/scheelite.yaml` (a real
token — theporndb.net/user/api-tokens) plus the API-key alias.

## Shuttle algorithm

Feed:

1. `GET /api/v3/queue?page=N&pageSize=<big>&includeUnknownSeriesItems=true`
   — paginate fully; dedupe rows by downloadId (one row per episode).
   Client-side filter (no server-side status filter at this build):
   `status == "completed"` AND `trackedDownloadStatus == "warning"`
   AND `trackedDownloadState in {importPending, downloading}`. Never
   query manualimport for non-completed items (HTTP 500).
1. Per downloadId: `GET /api/v3/manualimport?downloadId=X&filterExistingFiles=true`
   — never with `seriesId` (library-folder short-circuit, see Verified
   constraints). Feedable = video file with no episodes assigned OR
   with rejections (this also covers the >100-file degraded shape).
1. Each feedable file not in state: if its extension is outside
   namer's pinned `target_extensions`, record + report as
   unsupported-extension (still hardlink it — the link doubles as the
   pack-pin); otherwise hardlink into `watch/` as
   `<downloadId>-<pathhash8>-<basename>` and record
   `{inode, size, downloadId, originalPath, fedAt, status}` in
   `${dataDir}/shuttle-state.json`.

Harvest:

1. Each file in `dest/`: stat → inode + size cross-check → state →
   `{downloadId, originalPath}`. Unmapped → report, leave for
   reconciliation.
1. `GET /api/v3/parse?title=<canonical basename>` → series + episode.
   - Series unknown → `/series/lookup?term=`, require an
     exact-normalized title match → `POST /series` (title, tvdbId from
     lookup, monitored=false, rootFolderPath + qualityProfileId copied
     from an existing series) → episodes arrive async via the
     auto-queued RefreshSeries → retry next tick. No confident lookup
     match → skip + report.
   - Series known but no episode: retry next tick with a bounded
     count; this shape is also what date-ambiguity returns (multiple
     scenes on one air date, title normalization mismatch), which no
     retry fixes — after N attempts (default 7 daily-equivalent), park
     - report as needs-human, distinct from awaiting-match.
   - `episode.hasFile == true` → first check
     `GET /api/v3/history?downloadId=X&eventType=3`: if OUR downloadId
     already has an import event, this is the crash-window replay —
     unlink the dest link, close the state entry, count as imported.
     Otherwise a genuine duplicate → park as needs-human + report; a
     human resolves. Parked entries (duplicates, ambiguity,
     import-failure) quiesce — no further API calls — and appear as a
     standing needs-human count in every sweep summary rather than
     being re-classified or re-tried.
1. Import, gated on pack completeness: a downloadId's files may be
   imported only when EVERY video file of that download has a scratch
   link (guarantees nothing is destroyed unlinked when Whisparr
   removes the torrent on import). Then ONE
   `POST /api/v3/command {name: ManualImport, importMode: "copy", files: [...]}` per downloadId, batching all its dest-matched files;
   per file: path (originalPath), folderName, seriesId, episodeIds,
   downloadId, and quality + languages echoed from the GET
   manualimport item, falling back to `/parse`'s parsedEpisodeInfo
   when the item lookup misses or carries Unknown (mandatory — nulls
   corrupt the import at this build; still-missing → defer + report).
   Poll the command (generous timeout — the copies are multi-GB and
   serial), then confirm via
   `GET /api/v3/history?downloadId=X&eventType=3` per file — command
   completion is NOT import success. Confirmed → unlink dest links,
   close state entries, and log `original → canonical` for false-positive
   eyeballing. Not confirmed → keep the dest link and state entry and
   retry next tick with a bounded attempts counter; park as needs-human
   at the bound (an unbounded prune-and-refeed loop would re-POST a
   failing import forever).
1. Orphan import (untracked): a dest file whose originalPath no longer
   exists (torrent gone — pack pin matched later, or out-of-band
   removal) is imported FROM ITS SCRATCH PATH via folder-mode manual
   import (no downloadId; same parse/series/hasFile guards; quality
   from the parse). Confirmation: episode hasFile flip (history has no
   downloadId to filter by). Confirmed → unlink → bytes freed.

Reconciliation (every sweep, after harvest):

- For every file in all four scratch dirs: `stat`. `st_nlink == 1`
  means the original is gone — the link is now a pin. Pins in `dest/`
  → route to orphan import (above). Pins in `watch//work//failed/` →
  keep (deliberate pack-pin behavior) but report each with its size;
  these are the ONLY bytes the scratch area can ever hold.
- State entries whose originalPath is gone AND have no surviving
  scratch link → close + report (resolved out-of-band).
- `work/` entries older than one day → report (watchdog wedge; the
  ExecStartPre sweep recovers them on the next namer restart).
- Emit the sweep summary: fed / imported (tracked + untracked) /
  awaiting-match / needs-human (parse-ambiguous, duplicates,
  unsupported-extension, unmapped) / pinned (count + bytes) / errors.

Idempotency rests on three legs: history-based confirmation (replays
are detected), state keyed by inode+size with pruning (no stale
mappings), and reconciliation (links never outlive their purpose
silently). If Whisparr is down the sweep aborts cleanly and the timer
retries.

## Edge cases & policies

| Case                                                        | Policy                                                                                                                                                                                                 |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Multi-file pack, partial match                              | Import matched files (pack-completeness-gated), siblings survive as pins; reported with sizes; later matches import untracked                                                                          |
| Scene already has a library file                            | History-check first (own crash replay → close); genuine duplicate → skip + report — the manual-import API would otherwise silently REPLACE library files (no spec evaluation)                          |
| namer false-positive phash match                            | Guards are exact distance-0 + multi-candidate nullification (duration only annotates); report shows original→canonical for eyeballing; fix in Whisparr if wrong                                        |
| Duplicate matched twice (dest ` (N)` suffix)                | The suffixed name still parses (suffix precedes the extension); it will hasFile-skip → needs-human report                                                                                              |
| TPDb site name ≠ Whisparr series title                      | `/parse` leans on Whisparr's alias mappings; failures land in needs-human; no alias table until reality proves the need                                                                                |
| Same-date multi-scene ambiguity                             | Bounded retries then park + needs-human (retrying forever cannot fix it)                                                                                                                               |
| Hardlink `EPERM`                                            | `fs.protected_hardlinks` + 0644 files: fixed by qBt `UMask=0002` (new files) + one-time `chmod -R g+w` (backlog); feed reports clearly if hit                                                          |
| Queue item's file missing on disk                           | Skip + report; reconciliation closes its state                                                                                                                                                         |
| JAV in the stuck set                                        | No TPDb phashes → `failed/`; handled via Whisparr's JAV tab; no special-casing                                                                                                                         |
| Extensions namer ignores (.wmv etc. beyond the pinned list) | Fed as pin-links, reported as unsupported-extension, never processed by namer                                                                                                                          |
| Files manually dropped in `watch/`                          | Unsupported; reconciliation reports them unmapped. The manual surface is the web UI on `failed/`                                                                                                       |
| Whisparr / TPDb / namer down                                | Sweep no-ops with an error log; namer restarts recover work/ via ExecStartPre; nightly retry re-feeds failures                                                                                         |
| First-run burst (~103 files)                                | Single serial worker (phash ≈ seconds/file); unbounded watchdog queue (`queue_limit=0` default); 10-min request cache barely helps — politeness IS the serial worker; first run supervised             |
| Whisparr version bump                                       | Deployed build = frozen Jan-2026 nightly; queue status[] filter, ManualImportFile.IndexerFlags, reprocess semantics all change at tip — re-verify the "Verified at source" list before adopting a bump |

## Security & permissions

- namer and the shuttle never write video content anywhere — the only
  content write is Whisparr's library copy. namer writes small
  `*_namer.json.gz` sidecars (separate inodes) in `failed/`, consumed
  by its web UI and cleaned by its retry/success/delete paths.
- TPDb token and the API-key alias: sops, owner `namer`, mode 0400.
- Web UI: localhost bind + Kanidm forward-auth via Caddy; rename
  powers are containment-checked to the scratch dirs;
  `allow_delete_files` stays false (junk pins are removed by hand,
  guided by the reconciliation report).
- Unlinking a `dest/` link after confirmed import can never lose data
  (library copy exists); unlinking any pin is an explicit human act.

## Verification plan (implementation-time)

Much of the original plan was discharged by the source review
(commit `437da72`). Remaining live checks:

1. One-time sanity check of the request shapes against the live
   instance (key stays out of context — run curl on the host with the
   key read into a shell variable there): queue row shape for one
   stuck item, GET manualimport for it, `/parse` of a canonical name.
1. Confirm rendered namer.cfg by running `namer watchdog` once with
   the generated config (it self-verifies dirs/token and exits
   nonzero on error).
1. `stat` a backlog file as the `namer` user; apply the one-time
   `chmod -R g+w /tank0/downloads/whisparr` + qBt `UMask` and re-test
   the hardlink.
1. Supervised end-to-end on ONE single-file torrent: feed → match →
   harvest → import → history event → torrent removal (it is likely
   already paused: removal should be immediate) → dest cleanup →
   space actually freed. Then one multi-file pack if available. Then
   open the floodgates.
1. `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel`;
   deploy is run by the user.

## Implementation outline (commit sequence)

0. Prerequisite (manual, before deploy): `sudo zfs create` the
   `tank0/services/namer` dataset (legacy mountpoint, matching
   siblings).
1. `pkgs.namer` — edit package.nix to drop the JAV patch (delete
   `jav-auto-lookup.patch`), commit the package.
1. `nixosModules.theonecfg.services.namer` — watchdog + web service,
   rendered config (sops template), Caddy vhost, tmpfiles, hardening,
   secrets declarations, homepage tile; disko.nix dataset entry.
1. Shuttle script + `whisparr-namer-shuttle` service/timer in the same
   module.
1. `nixosConfigurations.scheelite` — enable + host paths
   (`dataDir = /tank0/services/namer`), qBt `UMask`, populate
   `secrets/scheelite.yaml` (`namer/tpdb-token`).
1. One-time backlog `chmod -R g+w`; supervised first run; then the
   backlog sweep; observe one full removal (immediate for paused
   torrents) and one 14-day lifecycle on a still-seeding rescue.

## Out of scope

- Sonarr/Radarr generalization (namer is TPDb/adult-specific).
- JAV automation (dead end — see `project_namer_package` memory and
  `stasharr-whisparr-eros-fork-investigation.md`).
- Auto-purge of never-matched downloads (pins are reported, never
  auto-deleted).
- The banked V2 + Eros side-by-side plan.
- SMTP/notification delivery for sweep reports (no relay yet).

## Remaining assumptions

1. Live behavior matches source-verified behavior at `437da72` —
   sanity-checked once against the running instance (verification
   step 1) before the shuttle ships.
1. qBt file modes: assumed 0644 today (nothing in the repo grants
   group-w); verification step 3 measures reality and the chmod +
   UMask fix covers both outcomes.
1. `HasReachedSeedLimit` recognizes the global `max_seeding_time` we
   set via preferences (source reads global limits from qBt's own
   config endpoint — expected to hold; observed directly in
   verification step 4 when the first import triggers an immediate
   removal).
