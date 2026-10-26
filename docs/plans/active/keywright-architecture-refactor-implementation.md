# Keywright Architecture Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Date: 2026-10-25
Status: active

**Goal:** Rename the flake-output directories, move package sources under `overlays/`, flatten the `theonecfg` package scope, replace the `hydraJobs` and `packages` flake outputs with release-lib jobset files plus one generic verify tool, and point CI at the two jobsets a free runner can finish, without changing what any host or home builds.

**Architecture:** Six `git mv` renames bring directory names in line with flake outputs. `overlays/default.nix` is rewritten around `packagesFromDirectoryRecursive` without `newScope`, with `fixes/`, `inputOverlays/`, `nixosTests/`, and `topLevel/` subdirectories. `hydra-jobs/` gains `packages.nix`, `nixos-configurations.nix`, and `home-configurations.nix` in the style of today's `images.nix`, which `nixos-configurations.nix` absorbs, and `theonecfg-verify-hydra-jobset` (keywright's script) evaluates and builds any of them. A recorded set of `.drvPath`s proves configurations are unchanged.

**Tech Stack:** Nix flakes, nixpkgs `lib.filesystem.packagesFromDirectoryRecursive`, nixpkgs `pkgs/top-level/release-lib.nix`, `nix-eval-jobs`, `nix-output-monitor`, treefmt (`nix fmt`), GitHub Actions.

**Spec:** `docs/plans/active/keywright-architecture-refactor.md`. Read it first; this plan argues from it.

## Global Constraints

- Nix only sees git-tracked files. Run `git add` on every new or moved file before any `nix` command, including the drvPath checks.
- `nix fmt` before every commit. `nix flake check` passes at every commit.
- Commit subjects are `<area>: <lowercase imperative>`, like the existing history (`hydra-jobs: add vm-tests.nix`). Every commit ends with the trailer `Assisted-by: Claude Code (claude-fable-5-1)`. No `Co-Authored-By`, no "Generated with".
- Never pass `newScope` to `packagesFromDirectoryRecursive`. Never create a scope in `pkgs`.
- Old attribute paths (`pkgs.theonecfg.*`, `pkgs.theonecfgTests`, `.#theonecfg.<package>`) must fail evaluation. No aliases, no shims.
- Do not touch `nixos-configurations/ilmenite/hibernation.nix`. It carries the user's unrelated, uncommitted work. Work on a branch in a git worktree (verified: `builtins.getFlake "git+file://<worktree>"` resolves), so that file never enters this branch.
- Do not refactor, rename, or clean up anything the spec does not name. Leave the stale `# monitor and bind-master uses IFD` comment in the workflow alone.
- Documentation paths are relative to the repository root. History is not rewritten: `docs/plans/completed/`, `docs/reports/`, `.git-blame-ignore-revs`.
- `$SCRATCH` below is a directory outside the repository (your session scratchpad). Nothing written there is committed.

## Review Focus

1. A module that references a renamed package behind a disabled `enable` option, such as the Brother driver, is evaluated by no host in `nix flake check`; a wrong name surfaces only when someone enables it. Task 3 evaluates that package's `drvPath` directly and greps modules for the old path.
1. A new directory under `overlays/topLevel/` that is not yet `git add`ed is silently absent from `packages.nix`, because `common.nix` sees the flake through `git+file://`. Task 4 compares the jobset's job names to the directory listing, and the README says so.
1. `allowAliases = false` in `legacyPackages` rejects any alias a local package or the NUR overlay still uses, breaking `nix shell .#`. Task 5 evaluates every top-level package and the formatter under the new config.
1. `nix build .#<package>` must keep working after the `packages` output is gone, by falling through to `legacyPackages`. Task 2 exercises the fallthrough.
1. A change that breaks home-manager evaluation now passes CI, since `nix flake check` does not know `homeConfigurations` and the build job is gone by decision. Task 4 pins the job list of `home-configurations.nix` by evaluation, and Task 7 builds it locally.

______________________________________________________________________

### Task 0: Record the configuration baseline

**Files:**

- Create: `$SCRATCH/drvpaths.nix` (outside the repo)
- Create: `$SCRATCH/baseline.json` (outside the repo)

**Interfaces:**

- Produces: `$SCRATCH/drvpaths.nix`, an expression every later drvPath check evaluates; `$SCRATCH/baseline.json`, the reference output.

- [ ] **Step 1: Create the worktree and branch, from the clean tip of `main`**

```bash
git worktree add -b djacu/keywright-architecture-refactor ../theonecfg-refactor main
cd ../theonecfg-refactor
git status --short   # expected: no output
```

- [ ] **Step 2: Write the drvPath expression**

Save as `$SCRATCH/drvpaths.nix`. It picks the ISO for live hosts, the VM for virtual hosts, and the toplevel otherwise, matching the spec's anti-goal.

```nix
let
  f = builtins.getFlake (toString ./.);
  inherit (f.theonecfg) knownHosts;
  system =
    host: cfg:
    let
      type = knownHosts.${host}.type;
      build = cfg.config.system.build;
    in
    if type == "live" then
      build.isoImage.drvPath
    else if type == "virtual" then
      build.vm.drvPath
    else
      build.toplevel.drvPath;
in
{
  nixos = builtins.mapAttrs system f.nixosConfigurations;
  home = builtins.mapAttrs (_: cfg: cfg.activationPackage.drvPath) f.homeConfigurations;
}
```

- [ ] **Step 3: Record the baseline**

Run, from the worktree root:

```bash
nix eval --json --impure --expr "$(cat "$SCRATCH/drvpaths.nix")" | jq -S . > "$SCRATCH/baseline.json"
jq -r '.nixos | keys[]' "$SCRATCH/baseline.json"
```

Expected: the seven host names `argentite cassiterite ilmenite malachite scheelite test-vm uraninite`, and `jq '.home | length'` prints `5`. Evaluation takes several minutes.

Later tasks repeat the first command into `$SCRATCH/after-task<N>.json` and run `diff "$SCRATCH/baseline.json" "$SCRATCH/after-task<N>.json"`, expecting no output.

______________________________________________________________________

### Task 1: Rename the flake-output directories

**Files:**

- Move: `formatter-module/` to `formatterModule/`, `home-configurations/` to `homeConfigurations/`, `home-modules/` to `homeModules/`, `legacy-packages/` to `legacyPackages/`, `nixos-configurations/` to `nixosConfigurations/`, `nixos-modules/` to `nixosModules/`
- Modify: `flake.nix` (six import paths)
- Modify: `overlays/default.nix` (`theonecfgModulesPath = ../nixos-modules;`)
- Modify: `nixosModules/services/pinchflat/module.nix` (comment citing `nixos-configurations/<host>/impermanence.nix`)
- Modify: `library/default.nix` (doc-comment examples mentioning `./home-modules` and `-home-modules/`)
- Modify: `CLAUDE.md` (the two `home-modules/...` auto-import lines)
- Modify: `README.md` (the `###` architecture headers and the sentence "Currently used in `legacy-packages`, `nixos-modules`, and `home-configurations`", and `cd nixos-configurations/scheelite`)

**Interfaces:**

- Produces: the six camelCase directories every later task references.

- [ ] **Step 1: Confirm the old paths are what the tree uses today**

Run: `grep -rn -E 'formatter-module|home-configurations|home-modules|legacy-packages|nixos-configurations|nixos-modules' --include=*.nix . | grep -v '^./docs/'`
Expected: hits in `flake.nix`, `overlays/default.nix`, `nixos-modules/services/pinchflat/module.nix`, `library/default.nix`, and nowhere else.

- [ ] **Step 2: Move the directories**

```bash
git mv formatter-module formatterModule
git mv home-configurations homeConfigurations
git mv home-modules homeModules
git mv legacy-packages legacyPackages
git mv nixos-configurations nixosConfigurations
git mv nixos-modules nixosModules
```

- [ ] **Step 3: Update the import paths and the three in-tree references**

In `flake.nix`, each `import ./<old> inputs` becomes `import ./<new> inputs`; leave the `hydraJobs` and `packages` lines for Task 2. In `overlays/default.nix`, `theonecfgModulesPath = ../nixosModules;`. In the pinchflat comment, `nixosConfigurations/<host>/impermanence.nix`. In `library/default.nix`, replace `home-modules` with `homeModules` in the doc comments only.

- [ ] **Step 4: Update CLAUDE.md and README.md**

CLAUDE.md: `homeModules/{programs,packages,services}/module.nix`, `homeModules/users/djacu/{programs,profiles}/module.nix`, `homeModules/users/djacu/programs/<name>/`. README.md: the six `###` headers take the new names, the "Currently used in" sentence and the `cd` step take the new names.

- [ ] **Step 5: Format and check**

Run: `nix fmt && nix flake check`
Expected: exits 0.

- [ ] **Step 6: Verify the moved module path still resolves for the VM test**

Run:

```bash
nix eval --raw --impure --expr 'let f = builtins.getFlake (toString ./.); in (f.legacyPackages.x86_64-linux.extend f.overlays.nixosTests).theonecfgTests.yubikey-live.drvPath'
```

Expected: a `/nix/store/...drv` path, no error.

- [ ] **Step 7: Verify configurations are unchanged**

Run the Task 0 eval into `$SCRATCH/after-task1.json`; `diff` against the baseline.
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "treewide: name flake output directories after their outputs" -m "Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 2: Remove the packages and hydraJobs outputs

**Files:**

- Delete: `packages/default.nix`, `hydra-jobs/default.nix`, `package-sets/top-level/theonecfg/verify-hydra-system-configs/`, `package-sets/top-level/theonecfg/verify-hydra-home-configs/`
- Modify: `flake.nix` (remove the `hydraJobs` and `packages` lines)
- Modify: `.github/workflows/pull-request.yml` (remove the two `nix-verify-hydra-*` jobs; keep `nix-checks` as is)

**Interfaces:**

- Produces: a flake with no `packages` or `hydraJobs` output; CI that runs only `nix flake check` until Task 4.

- [ ] **Step 1: Delete and edit**

```bash
git rm -r packages hydra-jobs/default.nix package-sets/top-level/theonecfg/verify-hydra-system-configs package-sets/top-level/theonecfg/verify-hydra-home-configs
```

Remove the two lines from `flake.nix`. Remove the `nix-verify-hydra-system-configs` and `nix-verify-hydra-home-configs` jobs from the workflow.

- [ ] **Step 2: Verify the outputs are gone and the fallthrough works**

Run: `nix eval .#packages 2>&1 | tail -1`
Expected: an error saying the flake does not provide attribute `packages`.

Run: `nix eval .#hydraJobs 2>&1 | tail -1`
Expected: the same kind of error for `hydraJobs`.

Run: `nix build --dry-run .#drduh-yubikey-guide`
Expected: exits 0, reporting what would be built or fetched (falls through to `legacyPackages`).

- [ ] **Step 3: Format and check**

Run: `nix fmt && nix flake check && nix shell .#actionlint -c actionlint .github/workflows/pull-request.yml`
Expected: exits 0, actionlint prints nothing.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "flake: drop the packages and hydraJobs outputs and their verify scripts" -m "CI runs only nix flake check until the jobset files land." -m "Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 3: Move package sources under overlays and flatten the theonecfg scope

**Files:**

- Move: `package-sets/top-level/` to `overlays/topLevel/`; `package-sets/nixos-tests/` to `overlays/nixosTests/`; `overlays/package-overrides/` to `overlays/fixes/`; `overlays/input-overlays/` to `overlays/inputOverlays/`
- Move: `overlays/topLevel/theonecfg/bootstrap-homelab-secrets/` to `overlays/topLevel/theonecfg-bootstrap-homelab-secrets/`; likewise `cups-brother-hll3280cdw` and `nom-check`; then remove the empty `overlays/topLevel/theonecfg/` and `package-sets/`
- Rewrite: `overlays/default.nix`
- Rewrite: `overlays/inputOverlays/nixvimcfg/overlay.nix`
- Modify: `nixosModules/hardware/brother-hll3280cdw/module.nix` (`pkgs.theonecfg.cups-brother-hll3280cdw`)
- Modify: `homeModules/programs/nixvimcfg/module.nix` (`pkgs.theonecfg.nixvimcfg`)
- Modify: `overlays/topLevel/theonecfg-bootstrap-homelab-secrets/bootstrap.sh` (usage comment `nix run .#theonecfg.bootstrap-homelab-secrets`)
- Modify: `hydra-jobs/common.nix` (remove the `extraOverlays` argument and its use)
- Modify: `hydra-jobs/vm-tests.nix` (remove `extraOverlays`; build `theonecfgNixosTests`)
- Modify: `CLAUDE.md` (the `nix run .#theonecfg.bootstrap-homelab-secrets -- scheelite` example; add a Naming section)

**Interfaces:**

- Produces: `pkgs.theonecfg-bootstrap-homelab-secrets`, `pkgs.theonecfg-cups-brother-hll3280cdw`, `pkgs.theonecfg-nom-check`, `pkgs.theonecfg-nixvimcfg`, `pkgs.theonecfgNixosTests.yubikey-live`; overlay outputs `default`, `fixes`, `nixosTests`, `nixvimcfg`, `topLevel`; `overlays/topLevel/` as the directory Task 4's `packages.nix` lists.

- [ ] **Step 1: Move**

```bash
git mv package-sets/top-level overlays/topLevel
git mv package-sets/nixos-tests overlays/nixosTests
git mv overlays/package-overrides overlays/fixes
git mv overlays/input-overlays overlays/inputOverlays
for p in bootstrap-homelab-secrets cups-brother-hll3280cdw nom-check; do
  git mv "overlays/topLevel/theonecfg/$p" "overlays/topLevel/theonecfg-$p"
done
rmdir overlays/topLevel/theonecfg package-sets
```

- [ ] **Step 2: Rewrite `overlays/default.nix`**

The spec fixes every name here, so the file is given in full. Composition order is today's with `nixosTests` inserted after `topLevel`.

```nix
inputs:
let

  # inherits

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    attrValues
    genAttrs
    recurseIntoAttrs
    ;

  inherit (lib.filesystem)
    listFilesRecursive
    packagesFromDirectoryRecursive
    ;

  inherit (lib.fixedPoints)
    composeManyExtensions
    ;

  inherit (lib.lists)
    filter
    ;

  inherit (inputs.self.library.path)
    getDirectoryNames
    ;

  # overlays

  # Fixes for upstream nixpkgs packages: every overlay.nix under ./fixes.
  fixes = composeManyExtensions (
    map import (filter (path: baseNameOf path == "overlay.nix") (listFilesRecursive ./fixes))
  );

  # One overlay per flake input that ships packages; each file takes `inputs`.
  inputOverlays = genAttrs (getDirectoryNames ./inputOverlays) (
    dir: import ./inputOverlays/${dir}/overlay.nix inputs
  );

  misc = _final: _prev: {
    # This repo's counterpart of nixpkgs' modulesPath: lets a VM test import
    # a NixOS module by path without going through the flake outputs.
    theonecfgModulesPath = ../nixosModules;
  };

  # VM tests, nested like nixpkgs' nixosTests.
  nixosTests = final: _prev: {
    theonecfgNixosTests = recurseIntoAttrs (packagesFromDirectoryRecursive {
      inherit (final) callPackage;
      directory = ./nixosTests;
    });
  };

  # No newScope: with it the root directory becomes a scope whose bookkeeping
  # attributes leak into pkgs.
  topLevel =
    final: _prev:
    packagesFromDirectoryRecursive {
      inherit (final) callPackage;
      directory = ./topLevel;
    };

in
inputOverlays
// {

  inherit
    fixes
    nixosTests
    topLevel
    ;

  default = composeManyExtensions (
    [
      fixes
      inputs.nur.overlays.default
      topLevel
      nixosTests
      misc
    ]
    ++ (attrValues inputOverlays)
  );

}
```

- [ ] **Step 3: Rewrite the nixvimcfg input overlay**

`overlays/inputOverlays/nixvimcfg/overlay.nix`:

```nix
inputs: final: _prev: {
  theonecfg-nixvimcfg = inputs.nixvimcfg.packages.${final.stdenv.hostPlatform.system}.default;
}
```

- [ ] **Step 4: Update the two module consumers, the bootstrap usage comment, and CLAUDE.md**

`pkgs.theonecfg-cups-brother-hll3280cdw` in the Brother module; `pkgs.theonecfg-nixvimcfg` in the nixvimcfg home module; `nix run .#theonecfg-bootstrap-homelab-secrets -- <hostname>` in `bootstrap.sh` and `nix run .#theonecfg-bootstrap-homelab-secrets -- scheelite` in CLAUDE.md. Add to CLAUDE.md, after the "Nix module style" section:

```markdown
## Naming

- A directory that produces a flake output or an overlay attribute is spelled exactly like that attribute: `nixosConfigurations/`, `overlays/topLevel/`. Directories that produce no attribute stay kebab-case: `hydra-jobs/`.
- Repo-owned packages are flat top-level attributes prefixed `theonecfg-` (`pkgs.theonecfg-nom-check`); third-party software keeps its upstream name (`pkgs.namer`). Never create a scope in `pkgs`; do not pass `newScope` to `packagesFromDirectoryRecursive`.
- VM tests live under `overlays/nixosTests/<name>/package.nix` and are exposed as `pkgs.theonecfgNixosTests.<name>`, like nixpkgs' `nixosTests`.
```

- [ ] **Step 5: Fold the tests overlay out of the jobset plumbing**

`hydra-jobs/common.nix`: delete the `extraOverlays ? [ ]` argument with its comment and the `++ extraOverlays` so `overlays = [ self.overlays.default ];`. `hydra-jobs/vm-tests.nix`: the `import ./common.nix (args // { inherit supportedSystems; extraOverlays = ...; })` keeps only `inherit supportedSystems;` and its comment; the final expression becomes `mapTestOn (packagePlatforms { inherit (pkgs) theonecfgNixosTests; })`.

- [ ] **Step 6: Verify the new attribute set**

Run:

```bash
git add -A
nix eval --json .#legacyPackages.x86_64-linux --apply 'p: {
  leak = p ? overrideScope;
  tests = builtins.attrNames p.theonecfgNixosTests;
  cups = p.theonecfg-cups-brother-hll3280cdw.drvPath;
  nvim = p.theonecfg-nixvimcfg.drvPath;
  nom = p.theonecfg-nom-check.drvPath;
  bootstrap = p.theonecfg-bootstrap-homelab-secrets.drvPath;
  test = p.theonecfgNixosTests.yubikey-live.drvPath;
}'
nix eval .#overlays --apply builtins.attrNames
```

Expected: `leak` is `false`, `tests` is `["recurseForDerivations","yubikey-live"]`, the five drvPaths are store paths; the overlay names are `["default","fixes","nixosTests","nixvimcfg","topLevel"]`.

- [ ] **Step 7: Verify the old paths fail and nothing references them**

Run: `nix eval .#legacyPackages.x86_64-linux.theonecfg 2>&1 | tail -1`
Expected: an error that attribute `theonecfg` is missing.

Run: `grep -rn -E 'pkgs\.theonecfg\.|theonecfgTests|package-sets|extraOverlays|overrideScope' --include=*.nix --include=*.sh --include=*.yml . ; grep -nF '.#theonecfg.' CLAUDE.md`
Expected: no output. (`theonecfg.programs.*` and the other option namespaces in CLAUDE.md are not matched by the fixed string `.#theonecfg.`.)

- [ ] **Step 8: Verify the binary names are unchanged**

Run: `ls "$(nix build --no-link --print-out-paths .#theonecfg-nom-check)/bin" "$(nix build --no-link --print-out-paths .#theonecfg-bootstrap-homelab-secrets)/bin"`
Expected: `nom-check` and `bootstrap-homelab-secrets`.

- [ ] **Step 9: Format, check, and compare**

Run: `nix fmt && nix flake check`, then the Task 0 eval into `$SCRATCH/after-task3.json` and `diff` against the baseline.
Expected: exit 0; no diff output.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "overlays: move package sources under overlays and flatten the theonecfg scope" -m "Repo-owned packages take a theonecfg- prefix. VM tests are pkgs.theonecfgNixosTests and the overlay is part of default, so the extraOverlays plumbing in hydra-jobs goes. newScope is dropped: it made the root directory a scope and leaked its attributes into pkgs." -m "Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 4: Jobset files, the verify tool, and CI

**Files:**

- Create: `hydra-jobs/packages.nix`, `hydra-jobs/nixos-configurations.nix`, `hydra-jobs/home-configurations.nix`
- Delete: `hydra-jobs/images.nix` (its ISO job moves into `nixos-configurations.nix`)
- Create: `overlays/topLevel/theonecfg-verify-hydra-jobset/package.nix`
- Rewrite: `.github/workflows/pull-request.yml`
- Modify: `README.md` (add a `### hydra-jobs` section)

**Interfaces:**

- Consumes: `overlays/topLevel/` directory names, `pkgs.theonecfgNixosTests` (Task 3); `self.theonecfg.knownHosts`, `self.library.path.getDirectoryNames` (existing).

- Produces: jobs `<package>.<system>`, `<host>.<system>`, `<host>-<user>.<system>`, `theonecfgNixosTests.<test>.x86_64-linux`; the command `nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/<file>.nix`.

- [ ] **Step 1: Write `hydra-jobs/packages.nix`**

Same argument header as `vm-tests.nix` but with both default systems, like `common.nix`:

```nix
{
  # The platforms supported.
  supportedSystems ? [
    "aarch64-linux"
    "x86_64-linux"
  ],

  # The system evaluating this expression.
  evalSystem ? builtins.currentSystem or "x86_64-linux",

  # The path to Nixpkgs.
  nixpkgs ? null,
}@args:
let

  inherit (import ./common.nix args)
    lib
    releaseLib
    self
    ;

  inherit (lib.attrsets)
    getAttrs
    ;

  inherit (releaseLib)
    mapTestOn
    packagePlatforms
    pkgs
    ;

  inherit (self.library.path)
    getDirectoryNames
    ;

in
# Every package directory under overlays/topLevel is a job.
mapTestOn (packagePlatforms (getAttrs (getDirectoryNames ../overlays/topLevel) pkgs))
```

- [ ] **Step 2: Write `hydra-jobs/nixos-configurations.nix`**

Model it on `images.nix`, which this file replaces: same header with both default systems, `inherit (import ./common.nix args) lib self;`, `hydraJob` from `lib.customisation`, `knownHosts` from `self.theonecfg`. The two bindings that matter:

```nix
  # Every nixosConfiguration whose build platform is supported.
  hosts = filterAttrs (
    _: value: elem value.config.nixpkgs.buildPlatform.system supportedSystems
  ) self.nixosConfigurations;

  # What a host of each knownHosts type builds.
  build =
    name: value:
    let
      type = knownHosts.${name}.type;
    in
    if elem type [ "desktop" "laptop" "server" ] then
      value.config.system.build.toplevel
    else if type == "virtual" then
      value.config.system.build.vm
    else if type == "live" then
      value.config.system.build.isoImage
    else
      throw "NixOS configuration '${name}' has an unknown type '${type}'.";
```

Body: `mapAttrs (name: value: { ${value.config.nixpkgs.buildPlatform.system} = hydraJob (build name value); }) hosts`.

Then `git rm hydra-jobs/images.nix`.

- [ ] **Step 3: Write `hydra-jobs/home-configurations.nix`**

Same shape. Filter `self.homeConfigurations` on `elem value.config.nixpkgs.system supportedSystems`; body `mapAttrs (_: value: { ${value.config.nixpkgs.system} = hydraJob value.activationPackage; })`.

- [ ] **Step 4: Add the verify tool**

```bash
mkdir -p overlays/topLevel/theonecfg-verify-hydra-jobset
cp ../keywright/overlays/verification/verify-hydra-jobset/package.nix overlays/topLevel/theonecfg-verify-hydra-jobset/package.nix
```

The copy is verbatim. Its `name = baseNameOf ./.` now yields `theonecfg-verify-hydra-jobset`, which is the intended binary name.

- [ ] **Step 5: Verify every jobset's job list by evaluation**

Run, after `git add -A`:

```bash
jobs() { nix shell .#nix-eval-jobs -c nix-eval-jobs "$1" --arg supportedSystems '["x86_64-linux"]' --constituents --force-recurse 2>/dev/null | jq -r 'select(.error == null) | .attr' | sort; }
diff <(jobs ./hydra-jobs/packages.nix) <(ls overlays/topLevel | sed 's/$/.x86_64-linux/' | sort)
jobs ./hydra-jobs/nixos-configurations.nix
jobs ./hydra-jobs/home-configurations.nix
jobs ./hydra-jobs/vm-tests.nix
```

Expected: the first `diff` prints nothing (nine packages, including `theonecfg-verify-hydra-jobset`). The second prints all seven hosts, `argentite cassiterite ilmenite malachite scheelite test-vm uraninite`, each suffixed `.x86_64-linux`. The third prints five `<host>-djacu.x86_64-linux`. The fourth prints `theonecfgNixosTests.yubikey-live.x86_64-linux`. Evaluation of the configurations takes minutes.

- [ ] **Step 6: Run the verify tool on the two CI jobsets**

Run: `nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/packages.nix`
Expected: exits 0 after building the packages.

Run: `nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/vm-tests.nix`
Expected: exits 0 after the VM test runs (needs `/dev/kvm`).

Run: `ls "$(nix build --no-link --print-out-paths .#theonecfg-verify-hydra-jobset)/bin"`
Expected: `theonecfg-verify-hydra-jobset`.

- [ ] **Step 7: Rewrite the workflow**

```yaml
name: pull request checks
on:
  pull_request:
  push: # This is only run when PRs are merged into main
    branches:
      - main
  workflow_dispatch:
jobs:
  nix-checks:
    name: nix flake check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@main
      - uses: DeterminateSystems/magic-nix-cache-action@main
      - run: nix flake check -L
        # monitor and bind-master uses IFD
  nix-verify-packages:
    name: nix verify packages jobset
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@main
      - uses: DeterminateSystems/magic-nix-cache-action@main
      - run: nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/packages.nix
  nix-verify-vm-tests:
    name: nix verify vm-tests jobset
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@main
      - uses: DeterminateSystems/magic-nix-cache-action@main
      # Green must mean the VM tests ran. KVM on free public runners is an
      # undocumented perk; if it is absent, fail visibly rather than skip.
      - name: Assert KVM is available
        run: |
          echo "DETERMINATE_NIX_KVM=${DETERMINATE_NIX_KVM:-<unset>}"
          if [ "${DETERMINATE_NIX_KVM:-0}" != "1" ] || [ ! -w /dev/kvm ]; then
            echo "::error::No usable /dev/kvm; VM tests cannot run on this runner."
            exit 1
          fi
      - run: nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/vm-tests.nix --max-memory-size 6144
```

- [ ] **Step 8: Add the README section**

Under `## architecture`, alphabetically among the existing `###` headers:

````markdown
### hydra-jobs

Jobset files for Hydra, in nixpkgs' release-lib style.
Each file is a function producing `<job>.<system>` attributes and is evaluated by path, not through a flake output.

| file                       | jobs                                                                      |
| -------------------------- | ------------------------------------------------------------------------- |
| `packages.nix`             | every package under `overlays/topLevel/`                                  |
| `vm-tests.nix`             | every VM test under `overlays/nixosTests/`, as `theonecfgNixosTests.<test>` |
| `nixos-configurations.nix` | every host in `nixosConfigurations`: the toplevel, VM, or ISO its `knownHosts` type calls for |
| `home-configurations.nix`  | every `homeConfigurations.<host>-<user>` activation package               |

`theonecfg-verify-hydra-jobset` evaluates a jobset file and builds every job:

```sh
nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/packages.nix
```

CI runs `packages.nix` and `vm-tests.nix`.
The configuration jobsets do not fit a free runner; run them locally before merging a change to a host or a user.

The jobset files see the flake through `builtins.getFlake "git+file://..."`, which only sees git-tracked files.
A new directory must be `git add`ed before any jobset sees it.
````

- [ ] **Step 9: Format and check**

Run: `nix fmt && nix flake check && nix shell .#actionlint -c actionlint .github/workflows/pull-request.yml`
Expected: exits 0, actionlint prints nothing.

- [ ] **Step 10: Commit**

Three commits, in this order:

```bash
git add overlays/topLevel/theonecfg-verify-hydra-jobset
git commit -m "theonecfg-verify-hydra-jobset: init" -m "keywright's verify-hydra-jobset, copied verbatim. The directory name gives both the attribute and the binary." -m "Assisted-by: Claude Code (claude-fable-5-1)"
git add hydra-jobs README.md
git commit -m "hydra-jobs: add packages, nixos-configurations and home-configurations jobsets" -m "Jobs are <name>.<system>, as release-lib and nixos/release.nix produce. The nixosConfigurations dispatch comes from the deleted hydraJobs output with the key order flipped, and absorbs images.nix as the live branch." -m "Assisted-by: Claude Code (claude-fable-5-1)"
git add .github
git commit -m "ci: run the packages and vm-tests jobsets" -m "Not the configuration jobsets: six of the last seven runs of the NixOS build job failed on a free runner after 20 to 29 minutes." -m "Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 5: Configure legacyPackages like the jobsets

**Files:**

- Modify: `legacyPackages/default.nix`

**Interfaces:**

- Produces: `legacyPackages.<system>.config` with `allowAliases = false; allowUnfree = true;`.

- [ ] **Step 1: Confirm today's values**

Run: `nix eval --json .#legacyPackages.x86_64-linux --apply 'p: { aliases = p.config.allowAliases; unfree = p.config.allowUnfree; }'`
Expected: `{"aliases":true,"unfree":false}`.

- [ ] **Step 2: Add the config**

In the `import inputs.nixpkgs-unstable { ... }` call, add `config = { allowAliases = false; allowUnfree = true; };` after `overlays`, as `legacyPackages/default.nix` in keywright does.

- [ ] **Step 3: Verify the values and that everything still evaluates**

Run the Step 1 command again.
Expected: `{"aliases":false,"unfree":true}`.

Run:

```bash
for n in $(ls overlays/topLevel); do nix eval --raw ".#legacyPackages.x86_64-linux.$n.drvPath"; echo; done
nix eval --raw .#formatter.x86_64-linux.drvPath
nix eval --raw .#legacyPackages.x86_64-linux.theonecfgNixosTests.yubikey-live.drvPath
```

Expected: nine drvPaths, then two more; no error mentioning an alias.

- [ ] **Step 4: Format, check, commit**

Run: `nix fmt && nix flake check`
Expected: exits 0.

```bash
git add legacyPackages
git commit -m "legacyPackages: disallow aliases and allow unfree, matching hydra-jobs/common.nix" -m "Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 6: Documentation sweep

**Files:**

- Modify: every file under `docs/runbooks/`, `docs/README.md`, and `docs/plans/active/` except `keywright-architecture-refactor.md` and `keywright-architecture-refactor-implementation.md`

**Interfaces:**

- Produces: zero references to old paths or attribute names outside history and the two refactor documents.

- [ ] **Step 1: Count what the sweep will touch**

Run:

```bash
pattern='formatter-module|home-configurations|home-modules|legacy-packages|nixos-configurations|nixos-modules|package-sets|theonecfgTests|pkgs\.theonecfg\.'
grep -rlE "$pattern" docs/runbooks docs/README.md docs/plans/active | grep -v keywright-architecture-refactor | wc -l
```

Expected: about 20 files (the reviewer counted 17 active plans plus runbooks and `docs/README.md`).

- [ ] **Step 2: Apply the substitutions**

Over the same file list, in this order so the longer `package-sets` paths rewrite before the shorter one:

```bash
pattern='formatter-module|home-configurations|home-modules|legacy-packages|nixos-configurations|nixos-modules|package-sets|theonecfgTests|pkgs\.theonecfg\.'
files=$(grep -rlE "$pattern" docs/runbooks docs/README.md docs/plans/active | grep -v keywright-architecture-refactor)
sed -i -E \
  -e 's#package-sets/top-level/theonecfg/#overlays/topLevel/theonecfg-#g' \
  -e 's#package-sets/top-level/#overlays/topLevel/#g' \
  -e 's#package-sets/nixos-tests/#overlays/nixosTests/#g' \
  -e 's#\bformatter-module\b#formatterModule#g' \
  -e 's#\bhome-configurations\b#homeConfigurations#g' \
  -e 's#\bhome-modules\b#homeModules#g' \
  -e 's#\blegacy-packages\b#legacyPackages#g' \
  -e 's#\bnixos-configurations\b#nixosConfigurations#g' \
  -e 's#\bnixos-modules\b#nixosModules#g' \
  -e 's#\btheonecfgTests\b#theonecfgNixosTests#g' \
  -e 's#pkgs\.theonecfg\.#pkgs.theonecfg-#g' \
  $files
```

Then read `git diff --stat` and skim `git diff docs/runbooks` to confirm only paths changed. `nix eval .#theonecfg.knownHosts`-style commands in docs refer to the `theonecfg` flake output and are correct as they stand; the patterns above do not touch them.

- [ ] **Step 3: Verify the spec's grep**

Run:

```bash
grep -rnE 'package-sets|theonecfgTests\b|pkgs\.theonecfg\.|hydraJobs|\b(formatter-module|home-configurations|home-modules|legacy-packages|nixos-configurations|nixos-modules)\b' . \
  | grep -v -E '^\./(\.git/|docs/plans/completed/|docs/reports/|\.git-blame-ignore-revs|docs/plans/active/keywright-architecture-refactor)'
grep -rnF '.#theonecfg.' . | grep -v -E '^\./(\.git/|docs/plans/completed/|docs/plans/active/keywright-architecture-refactor)'
```

Expected: no output from either.

- [ ] **Step 4: Format, check, commit**

Run: `nix fmt && nix flake check`
Expected: exits 0 (mdformat may reflow the edited documents; that is fine).

```bash
git add docs
git commit -m "docs: update paths and attribute names for the keywright architecture refactor" -m "Completed plans and reports are history and keep their old paths." -m "Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 7: Final verification and plan completion

**Files:**

- Move: `docs/plans/active/keywright-architecture-refactor.md` and `docs/plans/active/keywright-architecture-refactor-implementation.md` to `docs/plans/completed/`
- Modify: both documents' `Status:` lines

**Interfaces:**

- Consumes: everything above.

- [ ] **Step 1: Final drvPath comparison**

Run the Task 0 eval into `$SCRATCH/after-final.json`; `diff` against the baseline.
Expected: no output.

- [ ] **Step 2: Build the configuration jobsets locally**

Run, one at a time; these build full system and home closures and can take a long time:

```bash
nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/home-configurations.nix
nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/nixos-configurations.nix
```

Expected: each exits 0. The second builds the uraninite ISO along with the six systems. If `nixos-configurations.nix` fails on an upstream package build (the CI history shows paperless-ngx's test suite failing on runners), report the failing derivation and whether `main` fails on it the same way; such a failure is not caused by this refactor if the drvPath comparison in Step 1 is clean.

- [ ] **Step 3: The spec's remaining checks**

Run:

```bash
nix flake check
nix eval .#legacyPackages.x86_64-linux --apply 'p: p ? overrideScope'
nix eval .#legacyPackages.x86_64-linux.theonecfg 2>&1 | tail -1
```

Expected: exit 0; `false`; a missing-attribute error.

- [ ] **Step 4: Complete the plan**

Set `Status: implemented 2026-MM-DD` (today's date) in both documents, then:

```bash
git mv docs/plans/active/keywright-architecture-refactor.md docs/plans/active/keywright-architecture-refactor-implementation.md docs/plans/completed/
nix fmt && nix flake check
git add -A
git commit -m "docs/plans: complete keywright architecture refactor" -m "Assisted-by: Claude Code (claude-fable-5-1)"
```

- [ ] **Step 5: Report**

State: what changed (commit list), what is still open (CI results on the pull request are not visible until it is opened; the configuration jobsets' local build result from Step 2), and what was not verified (anything in Step 2 that did not finish).
