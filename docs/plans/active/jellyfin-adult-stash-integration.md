# Jellyfin Adult Library — Stash-Backed Metadata + Stacking Fix

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the "different versions of the same video" stacking on Jellyfin's Adult library and surface real per-scene metadata (title, performers, studio, posters) sourced live from Stash. Jellyfin remains the cast endpoint for TVs/Roku/Chromecast.

**Architecture:** Three orthogonal changes. (1) Break Jellyfin's stacking trigger by changing Whisparr's Standard Episode Format so filenames no longer start with the parent folder name (one trigger condition false → Jellyfin can't stack). (2) Bulk-rename existing imports via Whisparr's UI so the historical layout matches the new template. (3) Install `DirtyRacer1337/Jellyfin.Plugin.Stash` as a Nix-built plugin via a new `theonecfg.services.jellyfin.plugins` option; the plugin pulls metadata from local Stash (already deployed) by filename lookup against Stash's GraphQL API.

**Tech Stack:** NixOS; `buildDotnetModule` (.NET 9.0); `systemd.tmpfiles` symlinking the plugin into Jellyfin's plugins directory; Whisparr UI (no declarative rename push — manual is acceptable); existing Stash deployment.

## Background

The bug observed by the user: scenes inside `/tank0/media/adult/<Studio>/` show up in Jellyfin's Adult library as "alternate versions" of one item rather than as individual scenes. Confirmed via Jellyfin source (`Emby.Naming/Video/VideoListResolver.cs`): Movies-type libraries stack files in the same folder when **(a)** each filename starts with the parent folder name AND **(b)** all videos in the folder share the same release year. Whisparr's default Standard Episode Format is `{Site Title} - {Release-Date} - {Episode Title} [{Quality Full}]` inside folder `{Site Title}` — both conditions hit on every studio folder.

Stash is already deployed on scheelite (per the now-completed `investigate-stash-stasharr-portal-and-delegated-beacon.md` plan, Phase 1). Stash uses PHash to identify scenes against StashDB independently of filename. So renaming files on disk does not break Stash's identification — but Stash's path index does need to be re-scanned after rename so the Jellyfin plugin's filename lookups still resolve.

`DirtyRacer1337/Jellyfin.Plugin.Stash` is third-party, GPL-3.0, last release `1.2.0.3` (2025-10-22), targets `Jellyfin.Controller 10.11.6`. Standard `.NET 9.0` project, single-project solution, three deps: `Newtonsoft.Json 13.0.4`, `Jellyfin.Controller 10.11.6` (SDK), `ILRepack.Lib.MSBuild.Task` (build-time only — merges deps into a single dll). Risk: ILRepack runs as an MSBuild target; under `dotnet build` on Linux it has historically had edge cases. Fallback if it doesn't merge cleanly: drop ILRepack from build, install all bin/Release/net9.0/*.dll.

## Critical files

**To create:**

- `package-sets/top-level/jellyfin-plugin-stash/package.nix` — derivation (`package.nix`, not `default.nix`, matches the convention used by `stasharr-portal` and supported by `packagesFromDirectoryRecursive`)
- `package-sets/top-level/jellyfin-plugin-stash/deps.json` — generated NuGet lockfile

**To modify:**

- `nixos-modules/services/jellyfin/module.nix` — add `plugins` option + tmpfiles wiring
- `nixos-configurations/scheelite/default.nix` — enable the plugin

**To reference (read-only patterns to mirror):**

- `nixos-modules/services/whisparr/module.nix:1-230` — wrapper module skeleton (sops, Caddy, mkMerge layout). No code change here, but a useful style reference.
- `package-sets/top-level/stasharr-portal/package.nix` (committed by the prior plan) — example of a full Node app derivation in this repo's package-sets layout. Different build system, but same "vendored upstream pinned to a tag" shape.
- The upstream Jellyfin nixpkgs module at `nixos/modules/services/misc/jellyfin.nix` — note in particular: no `plugins` option exists upstream. `cfg.configDir` defaults to `${cfg.dataDir}/config` and the upstream module creates it via tmpfiles, so plugin symlinks under `${configDir}/plugins/` are safe to create after the upstream tmpfiles rules run.

## Pre-flight

- Branch: `rework-scheelite`. Each task that produces a commit ends in an atomic commit on this branch. **No `Co-Authored-By:` trailers** (per memory `feedback_no_coauthors.md`). **No future-refs** in commit messages — describe what's true at that point in history (per memory `feedback_commit_msg_no_future_refs.md`).
- For every new `.nix` file: immediately run `git add -N <path>` after creation. Nix flakes ignore untracked files; `nix flake check` reports `option does not exist` on freshly-created modules until they're at least intent-tracked (per memory `feedback_flake_untracked_files.md`).
- `nix flake check` is the cheap evaluation gate (~10-30s). `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel` is the full build gate (1-5 min). Run flake check between most tasks; toplevel build before deploys.
- The user runs every `nixos-rebuild --target-host` deploy themselves (interactive sudo password). Pre-deploy build verification is done from the workstation (per memory `feedback_nixos_rebuild_target_host.md`).
- Stash must be running on scheelite (it is, per the completed prior plan). Verify with `ssh scheelite "systemctl is-active stash"`.

---

## Phase 0 — Empirical verification

Goal: before changing anything, confirm the trigger rule actually matches the observed symptom and that the Jellyfin server's ABI is compatible with the plugin we'll install in Phase 3. **Go/no-go gate.**

### Task 0.1 — Confirm Jellyfin server is 10.11.x

**Steps:**

- [ ] **Step 1: Query the public info endpoint**

```bash
ssh scheelite "curl -fsS http://127.0.0.1:8096/System/Info/Public | jq -r '.Version'"
```

Expected: a version string starting with `10.11.` (e.g., `10.11.6`).

If the version is `10.10.x` or older: the plugin's targetAbi `10.11.0.0` will refuse to load. Stop the plan and either upgrade Jellyfin (likely already on unstable channel) or pick a compatible plugin release (the manifest lists 10.9.x and 10.8.x builds, but those won't be packaged here — would need a different plugin source).

If `10.12.x` or newer: spot-check whether the plugin still loads (Jellyfin's targetAbi check is a floor, not exact match in practice — but verify in Phase 3).

### Task 0.2 — Confirm the stacking trigger matches the symptom

**Steps:**

- [ ] **Step 1: Pick a studio folder that exhibits stacking in Jellyfin**

In Jellyfin UI → Adult library → find an item that shows multiple version dots / "Play other version" prompts. Note the parent folder (the Studio name).

- [ ] **Step 2: List the actual filenames on disk for that folder**

```bash
ssh scheelite "ls -la /tank0/media/adult/<Studio>/"
```

Replace `<Studio>` with the folder name from Step 1.

- [ ] **Step 3: Confirm both stacking-trigger conditions hold**

Verify two facts about the filenames:

- **(a)** Each filename starts with the folder name (the `{Site Title}` prefix from Whisparr's default template).
- **(b)** At least two of the videos share the same release year (the `{Release-Date}` token expanded to e.g. `2025-...`, `2025-...`).

If both are true: the plan's premise is verified. Proceed.
If only (a) is true (years differ): the symptom must have a different cause; investigate before changing template.
If (a) is false (filenames don't start with folder name): the symptom is something else; investigate before proceeding.

### Task 0.3 — Document an example before/after for one file

**Steps:**

- [ ] **Step 1: Pick one file path and write down its current name and target name**

Example (substitute real values):

- Current: `/tank0/media/adult/SiteName/SiteName - 2025-04-15 - Some Title [WEB-DL-1080p].mp4`
- Target after Phase 1 + Phase 2: `/tank0/media/adult/SiteName/2025-04-15 - SiteName - Some Title [WEB-DL-1080p].mp4`

Confirm with the user that the target shape matches expectations. **Do not proceed to Phase 1 without this confirmation.**

---

## Phase 1 — Whisparr Standard Episode Format change (UI)

Operational. No commits, no nix changes. The Whisparr "Naming" config lives in Whisparr's postgres DB (not its `config.xml`), and the user opted to set it manually rather than push declaratively.

### Task 1.1 — Open Whisparr's File Naming settings

**Steps:**

- [ ] **Step 1: Open the URL**

In a browser: `https://whisparr.scheelite.dev`. Authenticate via Kanidm forward-auth if prompted.

- [ ] **Step 2: Navigate to Settings → Media Management → File Naming**

Path in UI: top-right cog → `Settings` → `Media Management` → scroll to `Episode Naming` section.

### Task 1.2 — Verify "Rename Episodes" is enabled

**Steps:**

- [ ] **Step 1: Toggle**

Find the `Rename Episodes` checkbox. It must be **ON** for the rename template to apply to existing files in Phase 2. If it's off, turn it on.

If it was off: existing files were originally imported by Whisparr without applying its naming template at all (Whisparr just kept whatever filename the download came with). The Phase 2 rename will still work — Whisparr applies the template based on its own DB knowledge of the scene, regardless of the original filename.

### Task 1.3 — Set the new Standard Episode Format

**Steps:**

- [ ] **Step 1: Replace the value of "Standard Episode Format"**

Set it to:

```
{Release-Date} - {Site Title} - {Episode CleanTitle} [{Quality Full}]
```

Notes on token choice:

- `{Release-Date}` first → filename no longer starts with `{Site Title}` (= folder name) → Jellyfin's stacking trigger condition (a) breaks.
- `{Site Title}` second → still appears in filename for human readability, no other behavior depends on it.
- `{Episode CleanTitle}` over `{Episode Title}` → strips characters that confuse some filesystems (`?`, `:` etc.). Whisparr's default template uses `{Episode Title}`, but for our purpose `CleanTitle` is safer.
- `{Quality Full}` → keeps quality tag (e.g., `WEB-DL-1080p`) for at-a-glance.

Whisparr's preview area below the field will show what a sample filename looks like. Confirm it reads e.g. `2025-04-15 - SiteName - Some-Title [WEB-DL-1080p]`.

- [ ] **Step 2: Verify "Series Folder Format" is unchanged**

Should still be `{Site Title}`. We are not restructuring folders, only renaming files.

- [ ] **Step 3: Save**

Click `Save Changes` at the top of the page.

### Task 1.4 — Sanity-check by adding a new download

**Steps:**

- [ ] **Step 1: (Optional) trigger a new scene download in Whisparr**

If you have any pending scene to grab, let it complete. Verify that the imported file lands on disk with the new format. If you don't have one in flight, skip this — Phase 2 will exercise the template against existing files.

---

## Phase 2 — Bulk-rename existing files (Whisparr UI)

Operational. No commits, no nix changes. **After Phase 1; before Phase 3.** Phase 3's plugin queries Stash by filename, so files must be at their final names before metadata is refreshed.

### Task 2.1 — Preview the rename for one series (test run)

**Steps:**

- [ ] **Step 1: Navigate to the test series**

In Whisparr UI → `Series` (top nav). Pick a small studio (1–3 scenes) for the test run — keeps the verification cycle short.

- [ ] **Step 2: Open Rename Files preview**

On the series page, click the wrench icon (or `Manage Series` → `Rename Files`). Whisparr displays a preview of `Old → New` for each file.

- [ ] **Step 3: Sanity-check the preview**

Each row should show old filename starting with the studio name, new filename starting with the date. If any row shows "no change needed," that file is already in the new format (e.g., it was imported after Phase 1's setting change).

If the preview is empty: either the series has no files, or Whisparr's "Rename Episodes" toggle is still off (re-check Task 1.2).

### Task 2.2 — Apply rename for the test series

**Steps:**

- [ ] **Step 1: Click "Rename"**

Whisparr's UI button at the top of the preview list. The action is synchronous for small series; it issues `mv` syscalls for each file (atomic within the same filesystem; no data copy, no downtime).

- [ ] **Step 2: Verify on disk**

```bash
ssh scheelite "ls -la /tank0/media/adult/<TestStudio>/"
```

Expected: filenames now start with the date (`YYYY-MM-DD`).

### Task 2.3 — Re-scan Stash so its path index updates

**Stash discovers files by filesystem walk.** When Whisparr renames files on disk, Stash's DB still references the old paths until it re-scans. The Jellyfin plugin we install in Phase 3 queries Stash by filename — stale paths will mean the plugin can't match scenes.

**Steps:**

- [ ] **Step 1: Trigger Stash scan**

Stash UI: `https://stash.scheelite.dev` → Tasks (top nav) → click `Scan` next to the library entry pointing at `/tank0/media/adult`. Stash walks the directory tree, detects renamed files (PHash matches existing scene records), and updates the `path` column in its DB.

- [ ] **Step 2: Verify**

In Stash UI → Scenes → filter by the test studio. Spot-check that the file paths shown match the new names (date-prefixed).

If a scene now shows two files (one old, one new): Stash's PHash didn't match and it created a new scene record for the renamed file. Edit/merge in Stash, or accept the duplicate (no functional impact other than a stale row).

### Task 2.4 — Re-scan Jellyfin's Adult library

**Steps:**

- [ ] **Step 1: Trigger scan**

Jellyfin UI → Dashboard → Libraries → Adult → click the three-dot menu → `Scan Library Files`.

- [ ] **Step 2: Wait for completion**

Watch Dashboard → Tasks. The scan finishes when `Scheduled Library Scan` clears.

- [ ] **Step 3: Open the test studio in the Adult library**

Verify each scene now shows as a separate library item (no "alternate version" UI; no version dots on the tile). **This is the Phase 2 success criterion.** If scenes still appear stacked: the trigger rule from Phase 0.2 didn't actually break — investigate before mass-renaming.

### Task 2.5 — Bulk-rename the remaining series

**Steps:**

- [ ] **Step 1: Navigate to Mass Editor (or rename per-series)**

Whisparr UI → Series → top-right `Mass Editor` toggle (icon may say `Edit`). Select all series. There should be a `Rename Files` bulk action.

If the bulk option isn't available in your Whisparr version, fall back to per-series rename (Task 2.1+2.2) for each studio. Tedious but works.

- [ ] **Step 2: Apply**

Click `Rename Files` on the bulk selection. Wait for completion (a large library can take several minutes — Whisparr renames serially).

- [ ] **Step 3: Re-scan Stash**

Same as Task 2.3 but covering the whole library. If Stash's "Scan" task was already started in 2.3, it scanned the whole library — re-running is fine (Stash detects unchanged files quickly via mtime).

- [ ] **Step 4: Re-scan Jellyfin**

Same as Task 2.4 but the whole library.

### Task 2.6 — Note files that didn't get renamed

**Steps:**

- [ ] **Step 1: Find any files Whisparr doesn't know about**

```bash
ssh scheelite "find /tank0/media/adult -type f \( -name '*.mp4' -o -name '*.mkv' -o -name '*.avi' \) | head -50"
```

Spot-check filenames. Files that still start with the studio name (not a date) are files Whisparr doesn't have in its DB — likely manually placed by you, or imported before Whisparr started tracking them.

- [ ] **Step 2: Decide per file**

Options for each:

- **Manual `mv`** to the target name following the new template — preserves the file in place.
- **Re-import via Whisparr** — delete (or move out), then have Whisparr download from indexer, which lands the file with the new template.
- **Leave as-is** — accept that this file may still stack with similarly-named files. If it's a one-off, the impact is negligible.

This is an open-ended cleanup task; the plan doesn't enumerate every fix. Document in the user's notes what you decided per file.

---

## Phase 3 — Package and install Jellyfin.Plugin.Stash

Declarative. The actual code-change phase. Three commits planned: A) the package, B) the option in the jellyfin module (no host enablement), C) host enablement on scheelite.

### Task 3.1 — Verify a similar package isn't already in nixpkgs

**Steps:**

- [ ] **Step 1: Check nixpkgs**

```bash
nix search --no-write-lock-file nixpkgs jellyfin-plugin 2>&1 | head
```

Expected: no `jellyfin-plugin-stash` result. (Confirmed during plan-writing via the upstream Jellyfin module — no plugin-system support in nixpkgs.) If a package has appeared since: prefer the upstream package, skip Task 3.2 entirely, jump to Task 3.4.

### Task 3.2 — Create the package derivation

**Files:**

- Create: `package-sets/top-level/jellyfin-plugin-stash/package.nix`
- Create: `package-sets/top-level/jellyfin-plugin-stash/deps.json`

**Steps:**

- [ ] **Step 1: Write `package.nix`**

```nix
{
  lib,
  buildDotnetModule,
  fetchFromGitHub,
  dotnetCorePackages,
}:

buildDotnetModule (finalAttrs: {
  pname = "jellyfin-plugin-stash";
  version = "1.2.0.3";

  src = fetchFromGitHub {
    owner = "DirtyRacer1337";
    repo = "Jellyfin.Plugin.Stash";
    tag = finalAttrs.version;
    hash = lib.fakeHash;
  };

  projectFile = "Jellyfin.Plugin.Stash/Stash.csproj";
  nugetDeps = ./deps.json;

  dotnet-sdk = dotnetCorePackages.sdk_9_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_9_0;

  # Plugin is library-only; no executables to wrap into $out/bin.
  executables = [ ];

  # buildDotnetModule's `dotnet publish` lands files under
  # bin/Release/net9.0/<runtime-id>/ (linux-x64 here). ILRepack does not
  # run cleanly under `dotnet build` on Linux, so the merged single-dll
  # the upstream Windows CI produces does not happen here — install
  # both `Stash.dll` (renamed) and `Newtonsoft.Json.dll` separately.
  installPhase = ''
    runHook preInstall
    install -d $out/share/jellyfin-plugin-stash
    cp Jellyfin.Plugin.Stash/bin/Release/net9.0/linux-x64/Stash.dll \
       $out/share/jellyfin-plugin-stash/Jellyfin.Plugin.Stash.dll
    cp Jellyfin.Plugin.Stash/bin/Release/net9.0/linux-x64/Newtonsoft.Json.dll \
       $out/share/jellyfin-plugin-stash/Newtonsoft.Json.dll
    runHook postInstall
  '';

  meta = {
    description = "Jellyfin metadata plugin pulling adult-content scenes from a local Stash instance";
    homepage = "https://github.com/DirtyRacer1337/Jellyfin.Plugin.Stash";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
})
```

- [ ] **Step 2: Create an empty `deps.json` placeholder**

```bash
mkdir -p package-sets/top-level/jellyfin-plugin-stash
echo '[]' > package-sets/top-level/jellyfin-plugin-stash/deps.json
```

- [ ] **Step 3: Track the new files**

```bash
git add -N package-sets/top-level/jellyfin-plugin-stash/{package.nix,deps.json}
```

### Task 3.3 — Generate the real deps.json

**Steps:**

- [ ] **Step 1: Build to capture the src hash first**

```bash
nix build .#jellyfin-plugin-stash 2>&1 | tee /tmp/build.log
```

Expected: failure with `hash mismatch in fixed-output derivation '...src.drv'`. Output includes a `got: sha256-...` line.

Replace `lib.fakeHash` in `src.hash` with the captured value.

- [ ] **Step 2: Generate deps.json**

```bash
nix build .#jellyfin-plugin-stash.fetch-deps
./result
```

`fetch-deps` runs `dotnet restore` against the source, captures every NuGet dep, and writes `deps.json` to a path printed at the end (e.g., `/tmp/jellyfin-plugin-stash-deps.json` — exact path varies). Copy it into the repo:

```bash
cp /tmp/jellyfin-plugin-stash-deps.json \
   package-sets/top-level/jellyfin-plugin-stash/deps.json
```

If `./result` complains about the deps.json file's path: the script prints usage with `-h`. Read its output.

- [ ] **Step 3: Build the full package**

```bash
nix build .#jellyfin-plugin-stash 2>&1 | tee /tmp/build.log
```

Expected: succeeds. `result/share/jellyfin-plugin-stash/Jellyfin.Plugin.Stash.dll` exists.

If ILRepack fails (errors about MSBuild target not found, or about merging on Linux): apply the **fallback contingency**. Edit `package.nix`:

- Drop the ILRepack-aware install: `Jellyfin.Plugin.Stash/bin/Release/net9.0/Stash.dll` is no longer self-contained; it needs `Newtonsoft.Json.dll` alongside.
- Replace the `install -Dm644 ...` line with:
  ```bash
  install -d $out/share/jellyfin-plugin-stash
  cp Jellyfin.Plugin.Stash/bin/Release/net9.0/Stash.dll \
     $out/share/jellyfin-plugin-stash/Jellyfin.Plugin.Stash.dll
  cp Jellyfin.Plugin.Stash/bin/Release/net9.0/Newtonsoft.Json.dll \
     $out/share/jellyfin-plugin-stash/Newtonsoft.Json.dll
  ```
- Verify by running `nix build` again.

If the build still fails after the fallback, the **hard fallback** is to fetch the upstream release zip:

- Replace the body of `package.nix` with a `stdenv.mkDerivation` using `fetchurl` + `unzip` against `https://github.com/DirtyRacer1337/Jellyfin.Plugin.Stash/releases/download/1.2.0.3/Jellyfin.Plugin.Stash.zip` (sha256 from `manifest.json`: `89ea20b5e77f7cb1991567e33a4bca05` is an MD5; the sha256 needs to be captured at fetch time via `lib.fakeHash`).
- Drop the `deps.json`; not needed.
- Document this fallback in the resulting commit message so the choice is recoverable.

- [ ] **Step 4: Commit**

```bash
git add package-sets/top-level/jellyfin-plugin-stash/
git commit -m "package-sets/top-level/jellyfin-plugin-stash: package v1.2.0.3"
```

### Task 3.4 — Add `plugins` option to the jellyfin module

**Files:**

- Modify: `nixos-modules/services/jellyfin/module.nix`

**Steps:**

- [ ] **Step 1: Extend the `inherit (lib.types)` block**

The existing block (around line 20–25) imports `attrsOf`, `bool`, `int`, `str`. Add `listOf` and `package`:

```nix
inherit (lib.types)
  attrsOf
  bool
  int
  listOf
  package
  str
  ;
```

- [ ] **Step 2: Add the option declaration**

Locate the existing options block (around line 80–126 in current code). After `extraLibraries`, add:

```nix
plugins = mkOption {
  type = listOf package;
  default = [ ];
  description = ''
    Jellyfin plugin packages to install. Each package must place its
    dll(s) at `$out/share/<pname>/`. The module symlinks each into
    `${cfg.dataDir}/config/plugins/<pname>_<version>/` at activation
    time so Jellyfin's plugin loader picks them up.

    Plugin configuration (per-plugin settings, secrets) is set in the
    Jellyfin UI after install; that state persists in the same config
    directory.
  '';
};
```

- [ ] **Step 3: Add the tmpfiles wiring**

Inside the first `mkMerge` branch (the always-on one starting around line 129), after the existing `systemd.services.jellyfin.unitConfig.RequiresMountsFor` block, add:

```nix
systemd.tmpfiles.rules = [
  "d ${cfg.dataDir}/config/plugins 0755 jellyfin jellyfin - -"
] ++ map (
  plugin: "L+ ${cfg.dataDir}/config/plugins/${plugin.pname}_${plugin.version} - jellyfin jellyfin - ${plugin}/share/${plugin.pname}"
) cfg.plugins;
```

Notes:

- The `d` rule ensures the parent dir exists before symlinks land. The upstream module creates `${configDir}` itself but does not pre-create `plugins/` — Jellyfin creates it lazily on startup. We pre-create it deterministically.
- `L+` forces creation (removes existing symlink if path conflicts). Safe because the path is namespaced by `<pname>_<version>`; switching plugin versions invalidates the old symlink path automatically.
- The symlink target is `${plugin}/share/${plugin.pname}`, which is the convention enforced by the package derivation in Task 3.2 (`install -Dm644 ... $out/share/jellyfin-plugin-stash/...`).

- [ ] **Step 4: Run flake check**

```bash
nix flake check
```

Expected: passes. The new option has `default = [ ]`, so no host's behavior changes yet.

- [ ] **Step 5: Build the toplevel for scheelite (smoke test)**

```bash
nix build .#nixosConfigurations.scheelite.config.system.build.toplevel
```

Expected: succeeds. Confirms the module change doesn't break evaluation against the real host config.

- [ ] **Step 6: Commit**

```bash
git add nixos-modules/services/jellyfin/module.nix
git commit -m "nixos-modules/services/jellyfin: add plugins option"
```

### Task 3.5 — Enable the plugin on scheelite

**Files:**

- Modify: `nixos-configurations/scheelite/default.nix`

**Steps:**

- [ ] **Step 1: Set the `plugins` list on the jellyfin service block**

Locate the existing `theonecfg.services.jellyfin = { ... }` block. Add `plugins`:

```nix
jellyfin = {
  enable = true;
  # ... existing config ...
  plugins = [ pkgs.jellyfin-plugin-stash ];
};
```

(`pkgs.jellyfin-plugin-stash` is wired via the existing `packagesFromDirectoryRecursive` in `overlays/default.nix:48-54` — adding the new directory under `package-sets/top-level/` is enough for the attribute to exist.)

- [ ] **Step 2: Build the toplevel**

```bash
nix build .#nixosConfigurations.scheelite.config.system.build.toplevel
```

Expected: succeeds. Confirms plugin derivation builds and module wiring evaluates.

- [ ] **Step 3: Commit**

```bash
git add nixos-configurations/scheelite/default.nix
git commit -m "nixos-configurations/scheelite: install jellyfin-plugin-stash"
```

### Task 3.6 — Deploy to scheelite

**Operational task** (no commit).

**Steps:**

- [ ] **Step 1: Deploy**

```bash
nixos-rebuild --flake .#scheelite --target-host scheelite --sudo --ask-sudo-password switch
```

Expected: switch succeeds. The new tmpfiles rule creates `${configDir}/plugins/jellyfin-plugin-stash_1.2.0.3 → /nix/store/...` symlink. Jellyfin re-reads its plugin directory on next start.

- [ ] **Step 2: Restart Jellyfin so it loads the plugin**

systemd activation does NOT automatically restart Jellyfin when only tmpfiles change. Force it:

```bash
ssh scheelite "sudo systemctl restart jellyfin"
```

- [ ] **Step 3: Verify the symlink**

```bash
ssh scheelite "ls -la /tank0/services/jellyfin/config/plugins/"
```

Expected: a symlink `jellyfin-plugin-stash_1.2.0.3 -> /nix/store/.../share/jellyfin-plugin-stash`.

- [ ] **Step 4: Verify Jellyfin loaded the plugin**

```bash
ssh scheelite "journalctl -u jellyfin --since '2 minutes ago' --no-pager | grep -i 'plugin\|stash'"
```

Expected: a log line indicating the Stash plugin loaded (exact wording varies by Jellyfin version; look for "Stash" or the assembly name `Jellyfin.Plugin.Stash`).

If no matching log line: plugin path may be wrong, or ABI mismatch. Check `journalctl -u jellyfin -e` for errors. Common failures:

- "Plugin assembly not found" → symlink target is wrong; verify `$out/share/jellyfin-plugin-stash/` actually contains the dll.
- "Could not load … Jellyfin.Controller, Version=10.11.6.0" → ABI mismatch. Check Jellyfin's actual version (Phase 0.1) and confirm targetAbi compatibility.
- "Could not load … Newtonsoft.Json" → ILRepack didn't merge in deps. Apply the Task 3.3 contingency.

- [ ] **Step 5: Verify in the UI**

Open `https://jellyfin.scheelite.dev` → Dashboard → Plugins. `Stash` should appear in the list, with version `1.2.0.3`, status `Active`.

---

## Phase 4 — Configure plugin and verify metadata

Operational. After Phase 3 deploys cleanly.

### Task 4.1 — Generate a Stash API key

**Steps:**

- [ ] **Step 1: In Stash UI**

`https://stash.scheelite.dev` → Settings (cog icon) → Security → API Key.

- [ ] **Step 2: Generate or copy**

If a key already exists, copy its value. If not, click `Generate API Key`. Stash shows the key once — copy immediately.

### Task 4.2 — Configure the Jellyfin plugin

**Steps:**

- [ ] **Step 1: Open plugin config**

Jellyfin UI → Dashboard → Plugins → Stash → `Configure` (or click the plugin name).

- [ ] **Step 2: Set Stash server URL and API key**

- Server URL: `http://127.0.0.1:9999` (loopback to scheelite-local Stash; same loopback pattern the Stasharr Portal would use per its design — server-side fetches stay inside the host's network namespace).
- API Key: paste from Task 4.1.

If the plugin's UI has additional toggles (search-by-PHash, force matching, etc.), default values are fine for now.

- [ ] **Step 3: Save**

Plugin config persists at `${cfg.dataDir}/config/plugins/configurations/Stash.xml`. Survives Jellyfin restarts and rebuilds (tank0 storage).

### Task 4.3 — Trigger a metadata refresh on the Adult library

**Steps:**

- [ ] **Step 1: Refresh Metadata (Replace All)**

Jellyfin UI → Libraries → Adult → three-dot menu → `Refresh Metadata`. Choose `Replace existing metadata` (not just `Add missing`) — guarantees a clean re-resolve through the new plugin.

- [ ] **Step 2: Watch the job**

Dashboard → Tasks. The `Library Scan` (or `Refresh Metadata`) task progresses through every scene. On a large library this takes minutes to tens of minutes.

- [ ] **Step 3: Tail the journal during the scan**

```bash
ssh scheelite "journalctl -u jellyfin -f"
```

Expected: a stream of plugin lookups against `127.0.0.1:9999`. No 401 errors (would indicate API key wrong) or connection refused errors (would indicate Stash isn't running).

### Task 4.4 — Spot-check a sample of scenes

**Steps:**

- [ ] **Step 1: Open a scene tile in the Adult library**

Pick one that previously stacked. Confirm:

- Title shown matches the Stash scene title (not the filename).
- Cast list populated with performers.
- Studio shown.
- Poster / fanart present.
- Release year shown.
- Description / plot present (if Stash has one).

- [ ] **Step 2: Spot-check 3-5 more scenes across different studios**

Look for scenes that fail to populate. Common reasons:

- Stash doesn't have the scene identified (PHash didn't match StashDB) — plugin can't return metadata. Run Stash's `Identify` task on the scene to attempt match.
- Filename in Jellyfin doesn't resolve a Stash scene by path lookup — verify Stash's path index is current (Phase 2 Task 2.3 should have handled this; rerun Stash scan if needed).
- Plugin lookup hit an error — check journal for the specific scene.

### Task 4.5 — Cast verification

**Steps:**

- [ ] **Step 1: From a TV / Roku / Chromecast / phone client**

Open Jellyfin on a cast-target device. Navigate to the Adult library. Pick a scene. Cast / play.

Expected: device shows scene title, poster, optional cast list (depends on client). Stream plays.

- [ ] **Step 2: From the cast device's Now Playing UI**

Verify the title and poster are correct on the cast device's chrome (e.g., Chromecast's "Now Playing" overlay, Roku's playback header, smart-TV native UI).

This verifies the metadata propagates through Jellyfin's transcoding/streaming pipeline to clients — not just the web UI.

If metadata is missing at the cast device but present in the Jellyfin web UI: the client probably caches metadata; let it refresh or restart the client app.

---

## End-to-end verification

1. `nix flake check` passes.
2. `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel` succeeds.
3. Whisparr's Standard Episode Format is `{Release-Date} - {Site Title} - {Episode CleanTitle} [{Quality Full}]`.
4. Spot-check on disk: `ssh scheelite "ls /tank0/media/adult/<some-studio>/"` shows date-prefixed filenames.
5. Stash UI → Scenes → file paths reflect the new names.
6. Jellyfin UI → Adult library → scenes show as individual items (no stacking dots / "alternate version" UI), with Stash-sourced posters and titles.
7. Jellyfin UI → Dashboard → Plugins → `Stash` is listed as Active.
8. Casting from a TV / Roku / Chromecast displays scene title and poster correctly.

## Decisions deferred

- **Declarative plugin configuration** (templating `Stash.xml` to set the Stash URL and API key without UI clicks): out of scope. The XML schema isn't documented; UI configure once, persist on tank0 is acceptable.
- **Declarative Whisparr naming push** (a singleton-PUT helper for `/api/v3/config/naming`): user opted to set manually. If a future host's Whisparr should default to this format too, revisit and add a `theonecfg.services.whisparr.naming` option then.
- **Auto-trigger Stash scans after Whisparr renames**: nice-to-have; for now, manual via UI is fine. A `path-up` watcher or systemd `Path` unit could fire `stash --task scan` automatically. Not blocking.
- **Plugin auto-update** (newer plugin releases): manually bump the `version` and re-run `fetch-deps` in `package-sets/top-level/jellyfin-plugin-stash/`. Could be a future `update.nix` script, but yagni for now.

## Execution

Plan complete and saved to `docs/plans/active/jellyfin-adult-stash-integration.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
