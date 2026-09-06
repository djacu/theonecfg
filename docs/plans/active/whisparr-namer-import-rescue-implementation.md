# Whisparr Import Rescue (namer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rescue Whisparr's unimportable downloads by phash-identifying them with namer and importing them through Whisparr's own manual-import API, download-associated so torrent cleanup keeps working.

**Architecture:** An always-on `namer watchdog` service (matching + web UI) fed by an hourly "shuttle" oneshot that hardlinks stuck files into namer's watch dir, harvests canonical names from its dest dir, and drives Whisparr's manual-import API. All scratch operations are same-filesystem hardlinks/renames — zero data bytes; the only copy is Whisparr's import into the library. A reconciliation pass ties link/state lifecycles to reality.

**Tech Stack:** NixOS module (this repo's conventions), `pkgs.namer` (already packaged), Python 3 stdlib shuttle via `writers.writePython3Bin`, sops-nix secrets, systemd timer.

**Spec:** `docs/plans/active/whisparr-namer-import-rescue.md` — read it first; every design decision, verified API behavior, and edge-case policy lives there. This plan implements it exactly. (Plan reviewed 2026-09-05 by four adversarial reviews — including executing the nix tasks in a worktree and running the assembled test suite — and amended; the corrected API facts below override anything you might re-derive.)

## Global Constraints

- **Branch/PR:** create branch `djacu/whisparr-namer-rescue` in Task 1; all commits land there. Push and open a PR after Task 9 (CI must be green). Task 10 deploys from the local branch checkout; merge the PR after Task 10's supervised verification.
- **Formatter gate:** CI runs the repo formatter over the whole tree (`nixfmt` for .nix, `mdformat` for .md). Before EVERY commit: `nix fmt <files you touched>`. A commit that skips this fails CI.
- Repo conventions (CLAUDE.md): module skeleton `options.theonecfg.services.namer.enable = mkEnableOption ...` + `config = mkIf cfg.enable (mkMerge [...])`; inherit `mkEnableOption` from `lib.options`, `mkIf`/`mkMerge` from `lib.modules` in a `let` block. Auto-import handles new `nixos-modules/services/<name>/module.nix` — no manual wiring.
- **`git add -N <new files>` immediately after creating any new file** — nix cannot see untracked files.
- Validation command is `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel` (never `nix flake check` locally — too slow). Parse-only checks: `nix eval`.
- Commit subjects use nix attr paths for nix-reachable things (`pkgs.namer`, `nixosModules.theonecfg.services.namer`, `nixosConfigurations.scheelite`); file paths for docs. NO `Co-Authored-By` trailers. Commits describe what is true at that point in history.
- namer's effective defaults come from `namer.cfg.default`, NOT the `configuration.py` dataclass. The pins in Task 3's config are load-bearing (see spec "Effective-default traps") — do not "simplify" them away.
- The shuttle must never write file content under `/tank0/downloads` — hardlink (`os.link`), `stat`, `unlink` only. `importMode` is ALWAYS `"copy"` (`"auto"` MOVES paused torrents' files).
- **Never pass `seriesId` to `GET /api/v3/manualimport`** — the controller short-circuits into a series-LIBRARY-folder listing and ignores `downloadId` (verified at the deployed commit). This was wrong in an earlier draft; the spec's Verified-constraints section has the details.
- Whisparr API: camelCase JSON; localhost `http://127.0.0.1:6969`; auth via `X-Api-Key` header read from a file at runtime (never bake the key into the store or logs).
- Deploys are run by the user (`nixos-rebuild switch --flake .#scheelite --target-host djacu@scheelite --sudo --ask-sudo-password`); interactive sudo. The user's login shell on scheelite is FISH and sudo needs a TTY: remote commands with `$(...)`/`var=` syntax must be wrapped in `sh -c '...'`, sudo one-liners need `ssh -t`, and remote globs must be quoted.
- Python shuttle: stdlib only; the `writers.writePython3Bin` gate runs flake8 (`--ignore E501`) on **python 3.13** — run the unit tests with `#python3` (3.13), not `#python312`, so tests exercise the deployed interpreter.

## File Structure

```
package-sets/top-level/namer/package.nix        # MODIFY: drop JAV patch
package-sets/top-level/namer/jav-auto-lookup.patch  # DELETE
nixos-modules/services/namer/module.nix          # CREATE: options, namer.service,
                                                 #   config template, caddy, users,
                                                 #   secrets, tmpfiles, shuttle units
nixos-modules/services/namer/shuttle.py          # CREATE: the shuttle (feed/harvest/
                                                 #   reconcile), pure-stdlib
nixos-modules/services/namer/shuttle_test.py     # CREATE: unittest suite for shuttle
nixos-modules/services/homepage/module.nix       # MODIFY: one knownTiles entry
nixos-configurations/scheelite/disko.nix         # MODIFY: tank0/services/namer dataset
nixos-configurations/scheelite/default.nix       # MODIFY: enable + host paths + qBt UMask
secrets/scheelite.yaml                           # MODIFY (user runs sops): namer/tpdb-token
```

`shuttle.py` is structured as importable functions + `main()` so
`shuttle_test.py` can unit-test the decision logic without a live
Whisparr. Tests run via `nix shell .#python3` — no new test
infrastructure.

______________________________________________________________________

### Task 1: Branch + commit the design docs

**Files:**

- Commit (already written): `docs/plans/active/whisparr-namer-import-rescue.md`, `docs/plans/active/whisparr-namer-import-rescue-implementation.md`

- [ ] **Step 1: Create the working branch**

```bash
git switch -c djacu/whisparr-namer-rescue
```

- [ ] **Step 2: Format the docs (CI formatting check covers .md via mdformat)**

```bash
nix fmt docs/plans/active/whisparr-namer-import-rescue.md docs/plans/active/whisparr-namer-import-rescue-implementation.md
```

- [ ] **Step 3: Commit**

```bash
git add docs/plans/active/whisparr-namer-import-rescue.md docs/plans/active/whisparr-namer-import-rescue-implementation.md
git commit -m "docs/plans: add whisparr namer import-rescue design and implementation plan"
```

______________________________________________________________________

### Task 2: `pkgs.namer` — drop the exploratory JAV patch and commit

**Files:**

- Modify: `package-sets/top-level/namer/package.nix` (intent-to-add in the index; Step 4's `git add` stages the real content)
- Delete: `package-sets/top-level/namer/jav-auto-lookup.patch`

**Interfaces:**

- Produces: `pkgs.namer` (auto-exposed via the `packagesFromDirectoryRecursive` overlay; `${pkgs.namer}/bin/namer`) — consumed by Task 3.

- [ ] **Step 1: Remove the patch reference**

In `package-sets/top-level/namer/package.nix`, delete lines 118-123 —
the blank line ABOVE the comment block, the comment block, and the
`patches` attribute (leaving exactly one blank line between
`build-system = ...` and `dependencies = ...`; leaving two fails
nixfmt):

```nix

  # namer's automatic (CLI/watchdog) lookup only queries TPDb's /scenes and
  # /movies; its JAV support (/jav) is reachable only from the web UI. This
  # patch adds a /jav fallback to the auto path so JAV-coded releases match
  # headlessly. (Worth upstreaming.)
  patches = [ ./jav-auto-lookup.patch ];
```

- [ ] **Step 2: Delete the patch file**

```bash
git rm --cached package-sets/top-level/namer/jav-auto-lookup.patch 2>/dev/null || true
rm -f package-sets/top-level/namer/jav-auto-lookup.patch
```

- [ ] **Step 3: Build and format-check**

```bash
nix build --no-link .#legacyPackages.x86_64-linux.namer
nix fmt package-sets/top-level/namer/package.nix
```

Expected: build succeeds; `nix fmt` reports no changes (if it changed
the file, re-check Step 1's blank-line handling).

- [ ] **Step 4: Commit**

```bash
git add package-sets/top-level/namer/
git commit -m "pkgs.namer: package namer 1.19.20 with videohashes and web UI"
```

______________________________________________________________________

### Task 3: `nixosModules.theonecfg.services.namer` — watchdog service half

**Files:**

- Create: `nixos-modules/services/namer/module.nix`

**Interfaces:**

- Consumes: `pkgs.namer` (Task 2); existing options `theonecfg.services.qbittorrent.downloadsDir`, `theonecfg.services.whisparr.port`, `theonecfg.networking.lanDomain`, caddy snippets `acme_resolvers` / `forward_auth_kanidm`.

- Produces: options `theonecfg.services.namer.{enable,scratchDir,dataDir,port,domain,videoExtensions,settings,shuttle.enable,shuttle.interval}`; systemd unit `namer.service`; sops secret declaration `namer/tpdb-token`. Task 8 extends this same file (shuttle units + `whisparr/api-key-namer` alias); Task 4 references `svc.namer.{enable,domain}`.

- [ ] **Step 1: Write the module**

Create `nixos-modules/services/namer/module.nix`:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    mkMerge
    ;

  inherit (lib.options)
    mkEnableOption
    mkOption
    ;

  inherit (lib.types)
    anything
    attrsOf
    bool
    int
    listOf
    str
    ;

  cfg = config.theonecfg.services.namer;
  qbtCfg = config.theonecfg.services.qbittorrent;
  whisparrCfg = config.theonecfg.services.whisparr;

  # namer reads its config from the file named by NAMER_CONFIG (the only
  # config mechanism for `namer watchdog` — the subcommand has no -c flag).
  # IMPORTANT: namer.cfg.default (bundled in the package), not the
  # configuration.py dataclass, is the effective-defaults layer. Every pin
  # below that restates an apparent "default" exists because the bundled
  # cfg overrides the dataclass (update_permissions_ownership=True,
  # retry_time=<empty>, web=False, ...). See the design doc,
  # "Effective-default traps". Do not remove pins.
  #
  # namer's parser ignores EMPTY values (cannot clear a nonempty default,
  # only replace it) — so never render an empty string here.
  namerSettings = lib.recursiveUpdate {
    namer = {
      porndb_token = config.sops.placeholder."namer/tpdb-token";
      # Whisparr-parseable shape; used for `namer rename` CLI runs.
      inplace_name = "{full_site} - {date} - {name} [WEBDL-{resolution}].{ext}";
      # Default 300 (MiB) would silently skip short scenes.
      min_file_size = 0;
      write_namer_log = false;
      # Failed-side json.gz sidecars power the web UI's match% columns and
      # are cleaned up by namer's retry/success/delete paths. Keep them.
      write_namer_failed_log = true;
      target_extensions = lib.concatStringsSep "," cfg.videoExtensions;
      # LOAD-BEARING: effective default is True — namer would lchown/chmod
      # the qbt-owned shared inode, hit PermissionError, and strand files
      # in work/.
      update_permissions_ownership = false;
      database_path = cfg.dataDir;
      # Phash cache (keyed name,size,mtime — survives retry cycles and the
      # work/-sweep below) + requests cache.
      use_database = true;
      use_requests_cache = true;
      # convert_container_to MUST stay unset: it re-muxes into a NEW inode
      # (a full data copy on the downloads dataset + a broken inode
      # mapping). Absent here = namer's empty default = disabled.
    };
    Phash = {
      search_phash = true;
      # The Go videohashes tool (bundled) is the Stash-compatible hasher;
      # the pure-python alternative is "not 100% compatible" with TPDb.
      use_alt_phash_tool = false;
    };
    metadata = {
      # Tagging/posters write the shared inode → would corrupt the seeding
      # copy through the hardlink. Effective defaults are already false;
      # pinned so an upstream flip can't hurt.
      enabled_tagging = false;
      enabled_poster = false;
    };
    duplicates = {
      # If false, namer silently unlinks "losing" duplicates in dest/.
      preserve_duplicates = true;
    };
    watchdog = {
      del_other_files = false;
      queue_limit = 0;
      # The watchdog's dest naming key (NOT inplace_name). Default contains
      # a {full_site}/ subdirectory; pinned FLAT so the shuttle's harvest
      # is a flat scan of dest/.
      new_relative_path_name = "{full_site} - {date} - {name} [WEBDL-{resolution}].{ext}";
      watch_dir = "${cfg.scratchDir}/watch";
      work_dir = "${cfg.scratchDir}/work";
      failed_dir = "${cfg.scratchDir}/failed";
      dest_dir = "${cfg.scratchDir}/dest";
      # LOAD-BEARING: the shipped empty default means NO daily failed/
      # retry ever runs (the "random 3am" fallback is dead code). 03:17 =
      # dead hour, avoids racing a human in the web UI.
      retry_time = "03:17";
      # Web UI is OFF by effective default; it is the manual-match surface
      # for residuals.
      web = true;
      host = "127.0.0.1";
      port = cfg.port;
      allow_delete_files = false;
    };
  } cfg.settings;

  # Match namer.cfg.default's True/False literal style.
  toNamerIni = lib.generators.toINI {
    mkKeyValue = lib.generators.mkKeyValueDefault {
      mkValueString =
        v:
        if lib.isBool v then (if v then "True" else "False") else lib.generators.mkValueStringDefault { } v;
    } " = ";
  };

  # Files move watch→work at DETECTION time and namer refuses to start
  # (sys.exit -1) when work/ holds >1 MiB — a restart mid-burst would
  # crash-loop without this sweep. Same-fs renames; the shuttle's state is
  # inode-keyed and the phash cache is (name,size,mtime)-keyed, so nothing
  # is lost or recomputed. A same-named watch/ entry can only be the same
  # inode (link names are unique per download+path), so it's safe to drop
  # the work/ copy in that case.
  workSweep = pkgs.writeShellApplication {
    name = "namer-work-sweep";
    text = ''
      shopt -s nullglob dotglob
      for f in ${cfg.scratchDir}/work/*; do
        b=$(basename "$f")
        if [ -e "${cfg.scratchDir}/watch/$b" ]; then
          if [ "$f" -ef "${cfg.scratchDir}/watch/$b" ]; then
            rm -- "$f"
          else
            echo "namer-work-sweep: name collision, leaving $f" >&2
          fi
        else
          mv -- "$f" "${cfg.scratchDir}/watch/"
        fi
      done
    '';
  };

in
{
  options.theonecfg.services.namer = {
    enable = mkEnableOption "namer (phash-based import rescue for Whisparr)";
    scratchDir = mkOption {
      type = str;
      default = "${qbtCfg.downloadsDir}/.namer";
      description = ''
        Watch/work/failed/dest scratch area. MUST live on the same
        filesystem as the qBittorrent downloads (the pipeline is built on
        hardlinks); hence the default derives from
        ``theonecfg.services.qbittorrent.downloadsDir``.
      '';
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/namer";
      description = "Phash DB, requests cache, and shuttle state.";
    };
    port = mkOption {
      type = int;
      default = 6980;
    };
    domain = mkOption {
      type = str;
      default = "namer.${config.theonecfg.networking.lanDomain}";
    };
    videoExtensions = mkOption {
      type = listOf str;
      default = [
        "mp4"
        "mkv"
        "avi"
        "mov"
        "flv"
        "wmv"
        "m4v"
        "ts"
        "webm"
        "mpg"
        "mpeg"
      ];
      description = ''
        Extensions namer will process (its default list silently ignores
        anything else). The shuttle uses the same list to classify
        unsupported files it still pins.
      '';
    };
    settings = mkOption {
      type = attrsOf (attrsOf anything);
      default = { };
      description = ''
        Freeform INI overlay merged over the pinned defaults
        (section → key → value). namer's parser ignores empty values —
        you cannot clear a nonempty default, only replace it.
      '';
    };
    shuttle = {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Whisparr feed/harvest shuttle (needs whisparr enabled).";
      };
      interval = mkOption {
        type = str;
        default = "hourly";
        description = "systemd OnCalendar expression for the shuttle timer.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      users.users.namer = {
        isSystemUser = true;
        group = "namer";
        extraGroups = [ "media" ];
        home = cfg.dataDir;
      };
      users.groups.namer = { };

      sops.secrets."namer/tpdb-token".owner = "namer";

      sops.templates."namer.cfg" = {
        content = toNamerIni namerSettings;
        owner = "namer";
      };

      # namer creates none of its dirs (its config verify exits if any is
      # missing) — tmpfiles are mandatory. Scratch dirs follow the sgid
      # media-group idiom (see media-storage); dataDir is namer-private.
      systemd.tmpfiles.rules = [
        "d ${cfg.scratchDir} 2775 namer media - -"
        "d ${cfg.scratchDir}/watch 2775 namer media - -"
        "d ${cfg.scratchDir}/work 2775 namer media - -"
        "d ${cfg.scratchDir}/failed 2775 namer media - -"
        "d ${cfg.scratchDir}/dest 2775 namer media - -"
        "d ${cfg.dataDir} 0750 namer namer - -"
      ];

      systemd.services.namer = {
        description = "namer watchdog (phash matcher + web UI)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment.NAMER_CONFIG = config.sops.templates."namer.cfg".path;
        serviceConfig = {
          ExecStartPre = "${workSweep}/bin/namer-work-sweep";
          ExecStart = "${pkgs.namer}/bin/namer watchdog";
          User = "namer";
          Group = "namer";
          SupplementaryGroups = [ "media" ];
          # namer exits nonzero when TPDb is unreachable at startup.
          Restart = "on-failure";
          RestartSec = "30s";

          # Hardening (cloned from sonarr-anime / upstream services.sonarr,
          # minus its trailing "@chown" — namer must never chown: content
          # mutation through the shared inode corrupts seeding), plus
          # ProtectSystem=strict + ReadWritePaths scoped to scratch and
          # state — without ProtectSystem, ReadWritePaths is a no-op.
          ProtectSystem = "strict";
          ReadWritePaths = [
            cfg.scratchDir
            cfg.dataDir
          ];
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          ProtectHome = true;
          ProtectClock = true;
          ProtectKernelLogs = true;
          PrivateTmp = true;
          PrivateDevices = true;
          PrivateUsers = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          RemoveIPC = true;
          UMask = "0022";
          ProtectHostname = true;
          ProtectProc = "invisible";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
            "~@debug"
            "~@mount"
          ];
        };
        unitConfig.RequiresMountsFor = [
          cfg.scratchDir
          cfg.dataDir
        ];
      };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
```

Note: `whisparrCfg` is unused until Task 8 wires the shuttle; nix does
not warn on unused let bindings, so keep it.

- [ ] **Step 2: Make it visible to nix, format, and check evaluation**

```bash
git add -N nixos-modules/services/namer/module.nix
nix fmt nixos-modules/services/namer/module.nix
nix eval .#nixosConfigurations.scheelite.config.theonecfg.services.namer.enable
```

Expected: `nix fmt` makes no changes; eval prints `false` (options
exist and parse; module disabled).

- [ ] **Step 3: Full build (module parses inside the closure)**

```bash
nix build --no-link .#nixosConfigurations.scheelite.config.system.build.toplevel
```

Expected: builds (namer disabled → no behavior change).

- [ ] **Step 4: Commit**

```bash
git add nixos-modules/services/namer/module.nix
git commit -m "nixosModules.theonecfg.services.namer: namer watchdog service with pinned config"
```

______________________________________________________________________

### Task 4: Homepage tile

**Files:**

- Modify: `nixos-modules/services/homepage/module.nix` (the `knownTiles` list, Media group — after the Whisparr tile, ~line 116)

**Interfaces:**

- Consumes: `theonecfg.services.namer.{enable,domain}` (Task 3).

- [ ] **Step 1: Add the tile**

Find the Whisparr entry in `knownTiles` and add after it:

```nix
    {
      enabled = svc.namer.enable;
      group = "Media";
      name = "namer";
      href = publicUrl svc.namer.domain;
      icon = "mdi-rename-box";
      description = "phash import rescue";
      widget = null;
    }
```

(`svc` and `publicUrl` already exist in that file; gethomepage natively
supports `mdi-*` icon strings.)

- [ ] **Step 2: Format and build**

```bash
nix fmt nixos-modules/services/homepage/module.nix
nix build --no-link .#nixosConfigurations.scheelite.config.system.build.toplevel
```

Expected: no format changes; builds.

- [ ] **Step 3: Commit**

```bash
git add nixos-modules/services/homepage/module.nix
git commit -m "nixosModules.theonecfg.services.homepage: namer tile"
```

______________________________________________________________________

### Task 5: Shuttle — API client, state, and the feed phase

**Files:**

- Create: `nixos-modules/services/namer/shuttle.py`
- Create: `nixos-modules/services/namer/shuttle_test.py`

**Interfaces:**

- Consumes: env vars `WHISPARR_URL`, `WHISPARR_API_KEY_FILE`, `SCRATCH_DIR`, `STATE_FILE`, `TARGET_EXTENSIONS` (comma-separated), `AMBIGUITY_MAX_ATTEMPTS` (optional, default 168).

- Produces (exact signatures Tasks 6-7 build on):

  - `class WhisparrApi: __init__(self, base_url, api_key)`, `get(self, path, params=None)`, `post(self, path, body)` — return parsed JSON; raise `urllib.error.HTTPError`/`URLError` on failure.
  - `load_env() -> dict` with keys `url,key_file,scratch,state_file,exts,max_attempts`
  - `load_state(path) -> dict` / `save_state(path, state)` — schema `{"version": 1, "entries": {...}, "orphan_attempts": {...}}`; entry fields: `inode,size,download_id,original_path,link_name,fed_at,status,attempts,last_refresh` (`status ∈ fed|imported|needs_human`)
  - `is_video(name, exts) -> bool`
  - `path_hash(path) -> str` (8 hex chars), `state_key(download_id, path) -> str`, `link_name(download_id, path) -> str` (`f"{did}-{path_hash(path)}-{basename}"` — the hash disambiguates same-basename files in one pack)
  - `list_import_blocked(api) -> set[str]` (downloadIds)
  - `manual_import_items(api, download_id) -> list` (NEVER takes a seriesId — see Global Constraints)
  - `feedable(item) -> bool`
  - `feed(api, env, state) -> collections.Counter`
  - `main() -> int`

- File layout rule for all three shuttle tasks: module docstring, imports, constants, functions, `main()`, and the `if __name__ == "__main__":` block as the LAST two lines of the file — new code is always inserted BEFORE that block.

- [ ] **Step 1: Write the failing tests**

Create `nixos-modules/services/namer/shuttle_test.py`:

```python
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
```

```bash
git add -N nixos-modules/services/namer/shuttle_test.py
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd nixos-modules/services/namer && nix shell ../../..#python3 -c python3 -m unittest shuttle_test -v; cd -
```

Expected: FAIL / ERROR with `ModuleNotFoundError: No module named 'shuttle'`.

- [ ] **Step 3: Write the implementation**

Create `nixos-modules/services/namer/shuttle.py`:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
git add -N nixos-modules/services/namer/shuttle.py
cd nixos-modules/services/namer && nix shell ../../..#python3 -c python3 -m unittest shuttle_test -v; cd -
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add nixos-modules/services/namer/shuttle.py nixos-modules/services/namer/shuttle_test.py
git commit -m "nixosModules.theonecfg.services.namer: shuttle feed phase"
```

______________________________________________________________________

### Task 6: Shuttle — tracked harvest (parse, series add, hasFile, batched import, confirm)

**Files:**

- Modify: `nixos-modules/services/namer/shuttle.py`
- Modify: `nixos-modules/services/namer/shuttle_test.py`

**Interfaces:**

- Consumes: Task 5's `WhisparrApi`, state schema, `manual_import_items`, `state_key`/`link_name`.

- Produces (Task 7 builds on):

  - `canonical_stem(path) -> str` (basename minus extension)
  - `site_of(stem) -> str` (text before first `" - "`)
  - `normalize_title(s) -> str` (casefold, alnum only)
  - `scan_scratch(scratch) -> dict[int, list[Path]]` (inode → paths across all four dirs; tolerates files vanishing mid-scan)
  - `already_imported(api, download_id) -> set[int]` (episodeIds with history eventType=3)
  - `ensure_series(api, site) -> int | None` (existing/added seriesId, else None)
  - `pack_complete(items, inode_index) -> bool` (takes the already-fetched manualimport items — no second GET)
  - `harvest(api, env, state) -> Counter` (tracked path; nlink==1 dest files are counted `orphan_pending` and left for Task 7)
  - Updated `main()` running feed → harvest.

- Assembly rule: DELETE the old `def main()` entirely; insert all new functions and the new `main()` BEFORE the `if __name__ == "__main__":` block, which stays the last two lines of the file.

- [ ] **Step 1: Write the failing tests (append to shuttle_test.py, before its `if __name__` block)**

```python
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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

```bash
cd nixos-modules/services/namer && nix shell ../../..#python3 -c python3 -m unittest shuttle_test -v; cd -
```

Expected: Task 5 tests PASS; new tests ERROR (`AttributeError: module 'shuttle' has no attribute 'harvest'` etc.).

- [ ] **Step 3: Implement**

Append the following functions to `shuttle.py` (before `main()`), then
DELETE the old `def main()` and replace it with the version at the end
— the `if __name__ == "__main__":` block stays the last two lines:

```python
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
    except (urllib.error.URLError, OSError) as err:
        print(f"shuttle: aborted: {err}", file=sys.stderr)
        rc = 1
    save_state(env["state_file"], state)
    print("shuttle:", ", ".join(f"{k}={v}" for k, v in sorted(counters.items())) or "nothing to do")
    return rc
```

Implementation note: `already_imported` tolerates both enum-name and
numeric `eventType` serializations (STJson uses JsonStringEnumConverter
— names — but the numeric fallback is free).

- [ ] **Step 4: Run all tests**

```bash
cd nixos-modules/services/namer && nix shell ../../..#python3 -c python3 -m unittest shuttle_test -v; cd -
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add nixos-modules/services/namer/shuttle.py nixos-modules/services/namer/shuttle_test.py
git commit -m "nixosModules.theonecfg.services.namer: shuttle tracked harvest"
```

______________________________________________________________________

### Task 7: Shuttle — untracked orphan import, reconciliation, report

**Files:**

- Modify: `nixos-modules/services/namer/shuttle.py`
- Modify: `nixos-modules/services/namer/shuttle_test.py`

**Interfaces:**

- Consumes: everything above.

- Produces:

  - `import_untracked(api, dest_path) -> str` returning one of `"imported" | "duplicate" | "no_match"`
  - `orphan_imports(api, env, state, counters) -> None` (bounded per-inode attempts via `state["orphan_attempts"]`)
  - `reconcile(env, state) -> Counter`
  - Final `main()`: feed → harvest → orphan imports → reconcile, all inside the try; state saved and summary printed regardless.

- Assembly rule: same as Task 6 — new defs before the `if __name__` block; DELETE the old `def main()`; the guard stays the last two lines.

- [ ] **Step 1: Write the failing tests (append before the `if __name__` block)**

```python
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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

```bash
cd nixos-modules/services/namer && nix shell ../../..#python3 -c python3 -m unittest shuttle_test -v; cd -
```

Expected: new tests ERROR (`no attribute 'import_untracked'` / `'reconcile'` / `'orphan_imports'`).

- [ ] **Step 3: Implement**

Append before the `if __name__` block; DELETE the old `def main()` and
use the version below (guard stays last):

```python
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
```

- [ ] **Step 4: Run the full suite**

```bash
cd nixos-modules/services/namer && nix shell ../../..#python3 -c python3 -m unittest shuttle_test -v; cd -
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add nixos-modules/services/namer/shuttle.py nixos-modules/services/namer/shuttle_test.py
git commit -m "nixosModules.theonecfg.services.namer: shuttle orphan import and reconciliation"
```

______________________________________________________________________

### Task 8: Wire the shuttle into the module (service + timer + alias secret)

**Files:**

- Modify: `nixos-modules/services/namer/module.nix`

**Interfaces:**

- Consumes: `shuttle.py` (Tasks 5-7), `theonecfg.services.whisparr.port`, sops secret `whisparr/api-key` (aliased).

- Produces: `whisparr-namer-shuttle.service` + `.timer`; sops secret `whisparr/api-key-namer`.

- [ ] **Step 1: Add the shuttle derivation to the `let` block**

```nix
  shuttleBin = pkgs.writers.writePython3Bin "whisparr-namer-shuttle" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./shuttle.py);
```

- [ ] **Step 2: Add the shuttle units as a new mkMerge element**

Append to the `mkMerge` list (after the caddy block):

```nix
    (mkIf (cfg.shuttle.enable && whisparrCfg.enable) {
      # Read-only reuse of the existing whisparr/api-key sops entry under a
      # different owner (sops-nix `key` aliasing; single yaml entry).
      sops.secrets."whisparr/api-key-namer" = {
        key = "whisparr/api-key";
        owner = "namer";
      };

      systemd.services.whisparr-namer-shuttle = {
        description = "Feed Whisparr's import-blocked files to namer and import the matches";
        # after= only (no requires=): if whisparr is down the sweep exits 1
        # and Persistent=true retries next tick — no need to drag units up.
        after = [
          "namer.service"
          "whisparr.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${shuttleBin}/bin/whisparr-namer-shuttle";
          User = "namer";
          Group = "namer";
          SupplementaryGroups = [ "media" ];
        };
        environment = {
          WHISPARR_URL = "http://127.0.0.1:${toString whisparrCfg.port}";
          WHISPARR_API_KEY_FILE = config.sops.secrets."whisparr/api-key-namer".path;
          SCRATCH_DIR = cfg.scratchDir;
          STATE_FILE = "${cfg.dataDir}/shuttle-state.json";
          TARGET_EXTENSIONS = lib.concatStringsSep "," cfg.videoExtensions;
        };
        unitConfig.RequiresMountsFor = [
          cfg.scratchDir
          cfg.dataDir
        ];
      };

      systemd.timers.whisparr-namer-shuttle = {
        description = "Hourly whisparr-namer shuttle sweep";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.shuttle.interval;
          RandomizedDelaySec = "5m";
          Persistent = true;
        };
      };
    })
```

- [ ] **Step 3: Format and build (flake8 runs inside writePython3Bin here)**

```bash
nix fmt nixos-modules/services/namer/module.nix
nix build --no-link .#nixosConfigurations.scheelite.config.system.build.toplevel
```

namer is still disabled on scheelite, so also force the shuttle
derivation explicitly (this IS the flake8 gate):

```bash
nix build --no-link --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = f.legacyPackages.x86_64-linux; in pkgs.writers.writePython3Bin "whisparr-namer-shuttle" { flakeIgnore = [ "E501" ]; } (builtins.readFile ./nixos-modules/services/namer/shuttle.py)'
```

Expected: both build. A flake8 failure means shuttle.py has a style
error (E302 blank lines, unused import, etc.) — fix shuttle.py, re-run
the unit tests, then rebuild.

- [ ] **Step 4: Commit**

```bash
git add nixos-modules/services/namer/module.nix
git commit -m "nixosModules.theonecfg.services.namer: whisparr shuttle service and timer"
```

______________________________________________________________________

### Task 9: Enable on scheelite (disko dataset, host paths, qBt UMask, secret)

**Files:**

- Modify: `nixos-configurations/scheelite/disko.nix` (services datasets block)
- Modify: `nixos-configurations/scheelite/default.nix` (services block; a top-level `systemd` attr)
- Modify (USER runs sops): `secrets/scheelite.yaml`

**Interfaces:**

- Consumes: everything above.

- Produces: the deployable configuration; after this task, push the branch and open the PR.

- [ ] **Step 1: Add the disko dataset entry**

In `nixos-configurations/scheelite/disko.nix`, the `tank0/services/*`
block is insertion-ordered (not alphabetical) — append after the LAST
entry (`tank0/services/loki`):

```nix
          "tank0/services/namer" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/namer";
            options.mountpoint = "legacy";
          };
```

- [ ] **Step 2: Enable the service in default.nix**

In the `theonecfg.services` block, after the `whisparr` block (the
services are grouped by domain, not alphabetical):

```nix
          namer = {
            enable = true;
            dataDir = "${tankServicesDir}/namer";
          };
```

(`scratchDir` needs no override — it derives from
`qbittorrent.downloadsDir` = `/tank0/downloads` → `/tank0/downloads/.namer`.)

- [ ] **Step 3: qBt UMask for group-writable downloads**

New files must be 0664 so the `namer` user can hardlink them under
`fs.protected_hardlinks=1` (needs r+w for non-owners). At the top level
of the scheelite module's returned config (sibling to `theonecfg`, not
inside it), add:

```nix
      # Downloads must be group-writable (0664): fs.protected_hardlinks
      # requires rw for a non-owner (the namer user) to hardlink them for
      # the import-rescue pipeline. Existing files get a one-time
      # `chmod -R g+w /tank0/downloads/whisparr` at deploy time (see
      # docs/plans/active/whisparr-namer-import-rescue.md).
      systemd.services.qbittorrent.serviceConfig.UMask = "0002";
```

- [ ] **Step 4: Populate the TPDb token secret (USER runs this — never the agent: the token must not enter agent context or logs)**

The user runs:

```bash
sops set secrets/scheelite.yaml '["namer"]["tpdb-token"]' '"<real token from theporndb.net/user/api-tokens>"'
```

Gate (agent-safe; top-level yaml keys are plaintext, nothing is
decrypted):

```bash
grep -q '^namer:' secrets/scheelite.yaml && echo TOKEN-PRESENT
```

Expected: `TOKEN-PRESENT`. (Note: `nix eval` on the secret's `.path`
succeeds even when the yaml key is missing — it validates only the nix
declaration, so it is NOT a gate.)

- [ ] **Step 5: Format and build**

```bash
nix fmt nixos-configurations/scheelite/disko.nix nixos-configurations/scheelite/default.nix
nix build --no-link .#nixosConfigurations.scheelite.config.system.build.toplevel
```

Expected: builds with namer enabled (this forces the shuttle derivation

- flake8, the sops template, tmpfiles, and both units). A failure of the
  form `sops-install-secrets: manifest is not valid: ... the key 'namer' cannot be found` means Step 4 was not actually run — it is the
  build-time check for the yaml key.

* [ ] **Step 6: Commit, push, open the PR**

```bash
git add nixos-configurations/scheelite/disko.nix nixos-configurations/scheelite/default.nix secrets/scheelite.yaml
git commit -m "nixosConfigurations.scheelite: enable namer import rescue"
git push -u origin djacu/whisparr-namer-rescue
gh pr create --title "Whisparr import rescue via namer (phash)" --body "Implements docs/plans/active/whisparr-namer-import-rescue.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Wait for CI green before Task 10. Merge AFTER Task 10's supervised
verification.

______________________________________________________________________

### Task 10: Deploy and supervised live verification

No file changes until the final step — live host work, coordinated with
the user. The user's login shell on scheelite is fish and sudo needs a
TTY: sudo one-liners use `ssh -t`, `$(...)` syntax is wrapped in
`sh -c`, remote globs are quoted. Do not mark this task done on "the
deploy succeeded"; each numbered check is a distinct observation.

Timing context: the 14-day seed cap began accruing ~2026-09-05, so the
mass pause wave starts ~Sep 19. Until then most torrents are still
seeding — for them, "import succeeded, torrent still present" is the
EXPECTED outcome (removal fires at their pause). Only already-paused
torrents show immediate removal.

- [ ] **Step 1: Create the dataset on the live pool (BEFORE deploying) — user runs**

The pool is named `scheelite-tank0`; dataset paths are pool-relative
(the generated mount unit expects device
`scheelite-tank0/tank0/services/namer`):

```bash
ssh -t djacu@scheelite 'sudo zfs create -o mountpoint=legacy scheelite-tank0/tank0/services/namer'
```

Recovery if the deploy ran first: create the dataset, then
`sudo systemctl start tank0-services-namer.mount`, then Step 3's
tmpfiles fix.

- [ ] **Step 2: User deploys**

```bash
nixos-rebuild switch --flake .#scheelite --target-host djacu@scheelite --sudo --ask-sudo-password
```

- [ ] **Step 3: Fix the fresh dataset's ownership (first deploy only) — user runs**

At switch time, tmpfiles ran BEFORE the new dataset mounted (the switch
mounts new filesystems in a later phase), so `/tank0/services/namer` is
root-owned and namer can't write its DB/state until the next boot —
unless re-run now:

```bash
ssh djacu@scheelite 'stat -c "%U:%G %a" /tank0/services/namer'
ssh -t djacu@scheelite 'sudo systemd-tmpfiles --create && sudo systemctl restart namer.service'
ssh djacu@scheelite 'stat -c "%U:%G %a" /tank0/services/namer'
```

Expected: first stat likely `root:root 755`; after the fix:
`namer:namer 750`.

- [ ] **Step 4: One-time backlog chmod (after deploy = zero 0644 window; before the first sweep) — user runs**

The existing backlog files were created 0644 under the old umask; the
namer user cannot hardlink them until they're group-writable (inode
metadata only — safe for actively-seeding content):

```bash
ssh -t djacu@scheelite 'sudo chmod -R g+w /tank0/downloads/whisparr'
```

- [ ] **Step 5: Service health**

```bash
ssh djacu@scheelite 'systemctl status namer.service --no-pager | head -20'
ssh djacu@scheelite 'systemctl list-timers "whisparr-namer-shuttle*" --no-pager'
```

Expected: namer active (its config self-verify passed = dirs + TPDb
token OK); timer scheduled for the next hour boundary (+≤5m) — a fresh
timer does NOT fire at switch, which is why Step 8 starts the first
sweep manually. If namer is restart-looping, read
`journalctl -u namer -n 50 --no-pager` — config verify failure names
the bad directory/setting.

- [ ] **Step 6: Hardlink permission check (spec assumption 2) — user runs (interactive)**

```bash
ssh -t djacu@scheelite
# at the scheelite prompt:
sh -c 'f=$(find /tank0/downloads/whisparr -name "*.mp4" -print -quit); stat -c "%a %U:%G %n" "$f"; sudo -u namer ln "$f" /tank0/downloads/.namer/watch/permtest.bin && echo LINK-OK && sudo -u namer rm /tank0/downloads/.namer/watch/permtest.bin'
```

Expected: mode `66x` and `LINK-OK`. (`.bin` deliberately — a video
extension would let the live watchdog steal the test link mid-test.)

- [ ] **Step 7: Pre-ship API sanity (spec verification step 1) — user runs (interactive; key stays in a remote shell variable, never in agent context)**

```bash
ssh -t djacu@scheelite
# at the scheelite prompt:
sh -c 'key=$(sudo grep -oP "(?<=<ApiKey>)[^<]+" /tank0/services/whisparr/config.xml); curl -s -H "X-Api-Key: $key" "http://127.0.0.1:6969/api/v3/queue?page=1&pageSize=3&includeUnknownSeriesItems=true" | head -c 2000; echo'
# pick a downloadId from that output, then:
sh -c 'key=$(sudo grep -oP "(?<=<ApiKey>)[^<]+" /tank0/services/whisparr/config.xml); curl -s -H "X-Api-Key: $key" "http://127.0.0.1:6969/api/v3/manualimport?downloadId=<ID>&filterExistingFiles=true" | head -c 2000; echo'
sh -c 'key=$(sudo grep -oP "(?<=<ApiKey>)[^<]+" /tank0/services/whisparr/config.xml); curl -s -H "X-Api-Key: $key" "http://127.0.0.1:6969/api/v3/parse?title=Mom%20Swap%20-%202026-08-13%20-%20Test%20%5BWEBDL-1080p%5D" | head -c 2000; echo'
```

Expected: queue rows carry `downloadId`/`status`/`trackedDownloadState`;
manualimport items carry `path`/`episodes`/`rejections`/`quality`;
parse returns `series` + `episodes[].hasFile` for a canonical-shaped
title. Shapes matching the shuttle's expectations = assumption 1
discharged pre-ship.

- [ ] **Step 8: Supervised single-file end-to-end**

Check how many torrents are already paused (determines whether
immediate removal is observable now):

```bash
ssh djacu@scheelite 'curl -s "http://127.0.0.1:8080/api/v2/torrents/info?category=whisparr" | grep -oE "\"state\":\"(pausedUP|stoppedUP)\"" | sort | uniq -c'
```

Run one sweep manually and watch (oneshot blocks until the sweep ends —
the first full-backlog sweep can take a while; keep the session open):

```bash
ssh -t djacu@scheelite 'sudo systemctl start whisparr-namer-shuttle.service; journalctl -u whisparr-namer-shuttle -n 60 --no-pager'
ssh djacu@scheelite 'journalctl -u namer --since "-30min" --no-pager | tail -40'
ssh djacu@scheelite 'ls /tank0/downloads/.namer/dest | head; ls /tank0/downloads/.namer/failed | wc -l'
```

Then verify for ONE file (pick a single-file torrent from the summary):

1. Canonical file appeared in `dest/` and disappeared after the next
   sweep (`ls /tank0/downloads/.namer/dest`).
1. Whisparr: episode file exists under `/tank0/media/adult/...`, queue
   item gone; the shuttle journal shows `harvest: imported <original> -> <canonical>`.
1. qBt: if the torrent was already paused-at-limit → REMOVED
   immediately; if still seeding → still present (EXPECTED; removal
   fires at its 14-day pause). Check:
   `ssh djacu@scheelite 'curl -s "http://127.0.0.1:8080/api/v2/torrents/info?hashes=<hash>"'`
1. If removed: downloads dir for that release is gone;
   `ssh djacu@scheelite 'zfs list scheelite-tank0/tank0/downloads'`
   reflects freed space.
1. Jellyfin sees the new file.

- [ ] **Step 9: Supervised multi-file pack (if one exists in the backlog)**

Pick a stuck multi-video download from the sweep report. Observe:

1. While only some files are matched: `pack_deferred` in the summary,
   nothing imported, torrent + all data intact.
1. After all its files match (or you match the rest in the web UI at
   https://namer.scheelite.dev): ONE ManualImport per download, all
   files imported, dest links gone.
1. If the torrent then gets removed (paused case): any never-matched
   siblings would have shown as pins with sizes in the reconcile
   report — for a fully-matched pack there are none.

- [ ] **Step 10: Open the floodgates and monitor the burst**

Let the hourly timer run. The ~103-file backlog phashes serially
(seconds per file — the matching tail takes hours). Check afterwards:

```bash
ssh djacu@scheelite 'journalctl -u whisparr-namer-shuttle --since "-2h" --no-pager | tail -10'
ssh djacu@scheelite 'ls /tank0/downloads/.namer/failed | wc -l; ls /tank0/downloads/.namer/dest | wc -l'
```

Expected: summary lines with fed / imported / awaiting_match /
needs_human\_\* / pinned counts; `failed/` holds the JAV+OnlyFans
residual (visible in the web UI); no crash loops; `eperm=0` (nonzero
means Step 4's chmod missed files).

- [ ] **Step 11: Restart-resilience spot check — user runs**

```bash
ssh -t djacu@scheelite 'sudo systemctl restart namer.service && sleep 5 && systemctl is-active namer.service && ls /tank0/downloads/.namer/work | wc -l'
```

Expected: `active`, and `work/` drains back through `watch/` (the
ExecStartPre sweep) — no exit(-1) crash loop even mid-burst.

- [ ] **Step 12: Deferred observation (~Sep 19-20, aligns with the existing reclaim reminder)**

The scheduled Sep 20 reclaim check should now look at: (a) the pause
wave removing imported torrents (reclaim curve turns down sharply),
(b) the paused-but-unimported remainder shrinking via namer instead of
accumulating, (c) the reconcile report's pinned-bytes and eperm
counters, (d) one still-seeding rescue observed through its full
14-day pause → removal (spec outline step 5).

- [ ] **Step 13: Update the design doc status and memory; merge**

- Flip the spec's Status line to "implemented 2026-MM-DD; in
  observation".

- Update memory `project_namer_package.md` (namer committed + deployed;
  remove "uncommitted/parked" language) and
  `project_qbittorrent_settings_reset_on_deploy.md` (retroactive
  removal confirmed in source — the historical backlog self-cleans; the
  Sep 20 check is observational).

- Commit (formatted) and merge the PR:

```bash
nix fmt docs/plans/active/whisparr-namer-import-rescue.md
git add docs/plans/active/whisparr-namer-import-rescue.md
git commit -m "docs/plans: mark whisparr namer import-rescue implemented"
git push
```

______________________________________________________________________

## Self-Review Notes

- Reviewed 2026-09-05 by four adversarial subagent reviews (python
  executed + flake8-gated, nix tasks executed in a worktree, spec
  fidelity matrix, live-ops command audit); all surviving findings are
  incorporated: never-seriesId on manualimport, path-hashed link/state
  names, per-file harvest error isolation, parked-entry quiescence +
  standing needs-human counts, bounded in-place import retries, orphan
  attempt bounds, quality fallback to parse, rootFolderPath from an
  existing series, 900s command poll, history pageSize 1000, FNF-tolerant
  scans, reconcile inside the abort guard, work-sweep collision
  handling, pool name `scheelite-tank0`, post-deploy tmpfiles fix,
  post-deploy chmod ordering, fish/TTY-safe remote commands, pre-ship
  API sanity step, supervised pack stage, deferred 14-day observation,
  formatter gates, branch/PR flow, python3 (3.13) test interpreter.
- Spec coverage: package commit (T2), module + pins + hardening + caddy
  - tile (T3-T4), shuttle feed/harvest/orphan/reconcile with every
    reviewed policy (T5-T7), units + alias secret (T8), dataset/host/
    UMask/secret + PR (T9), deploy + ownership fix + chmod + sanity +
    supervised single-file + pack + floodgates + restart check + deferred
    observation + docs/memory/merge (T10). Snapshot-exclusion remains a
    spec note for the future backup plan — nothing to change today.
- Type consistency: state entry fields identical across T5 code and
  T6/T7 tests; `state_key`/`link_name`/`path_hash` used everywhere
  (no literal key strings in tests except deliberately synthetic ones
  in reconcile tests); batch tuple `(dest_path, key, entry, episode_ids, series_id, pei)` consistent between append and both
  unpack sites; `pack_complete(items, inode_index)` consistent between
  definition, harvest call, and its test (which exercises it through
  `harvest`).
