# Keywright architecture refactor

Date: 2026-10-25
Status: approved 2026-10-25. Implementation plan: `docs/plans/active/keywright-architecture-refactor-implementation.md`.

## Intent

Bring this repository's layout and CI machinery in line with
`../keywright`, which was built later and more deliberately. The two
repositories already share most of their hydra tooling (`hydra-jobs/common.nix`
and `vm-tests.nix` were ported from keywright; `images.nix` was written here in
the same style). What remains is a set
of inconsistencies that accumulated as that port landed piecemeal: two
coexisting jobset styles, two hard-coded verify scripts, a package scope that
exists only for namespacing, directory names that do not match the flake
outputs they produce, and a package set in `legacyPackages` that is configured
differently from the one CI builds.

Hydra itself is not set up yet. The jobset files are written now so that CI
exercises exactly what Hydra will later consume, and so that standing Hydra up
is a matter of pointing it at files that already work.

## Goals

- Every directory imported by `flake.nix` is named after the flake output it
  produces.
- Package sources live under `overlays/`, one subdirectory per overlay, as in
  keywright.
- One jobset style: plain release-lib files under `hydra-jobs/`, evaluated by
  path, never through a `hydraJobs` flake output.
- One generic verify tool, `verify-hydra-jobset JOBFILE`, replaces the two
  hard-coded scripts, and CI runs it once per jobset file.
- NixOS and home-manager configurations are built as hydra jobs in the shape
  nixpkgs uses in `nixos/release.nix`: `<name>.<system>`, wrapped in
  `lib.hydraJob`.
- `pkgs` gains no scopes. Repo-owned packages are flat top-level attributes
  with a `theonecfg-` prefix. VM tests are nested under one plain attribute
  set, `theonecfgNixosTests`, the way nixpkgs nests `nixosTests`.
- `legacyPackages` is configured identically to the package set the jobsets
  build.

## Non-goals

- Standing up Hydra, or writing a `release-combined`-style `tested` aggregate.
  Nothing would consume it yet.
- Restructuring `library/` to match keywright's `makeExtensible` layout.
- Changing any NixOS or home-manager module, host, or user configuration.
- Moving the NUR overlay out of `overlays/default.nix` into `inputOverlays/`.
- Rewriting completed plans under `docs/plans/completed/`. They are history.

## Anti-goals

- Any change to what a host or home configuration builds. Every
  `nixosConfigurations.<host>` toplevel (or ISO, or VM) and every
  `homeConfigurations.<host>-<user>` activation package must have the same
  `.drvPath` before and after this refactor. A diff means something other than
  a rename happened and must be explained before merging.
- Reintroducing a scope anywhere in `pkgs`, including by passing `newScope` to
  `packagesFromDirectoryRecursive`.
- Silent fallbacks. A reference to a removed attribute path, such as
  `pkgs.theonecfg.nom-check`, must fail evaluation, not resolve to something.

## Constraints

- Match the surrounding module and library style described in `CLAUDE.md`.
- The jobset files self-reference the flake through
  `builtins.getFlake "git+file://..."` in `hydra-jobs/common.nix`. That only
  sees git-tracked files. New directories must be `git add`ed before a jobset
  will see them. This is inherited from keywright and stays.
- `nix-eval-jobs` evaluates a plain file without `--impure` and still permits
  `builtins.currentSystem` and the unlocked `getFlake`. Verified on the current
  tree by evaluating `hydra-jobs/images.nix`.
- GitHub Actions runners: the VM test job must assert `/dev/kvm` is usable
  and fail visibly if not, as keywright's CI does.

## Design

### Directory layout

Renamed, directory after flake output:

| today                   | after                  |
| ----------------------- | ---------------------- |
| `formatter-module/`     | `formatterModule/`     |
| `home-configurations/`  | `homeConfigurations/`  |
| `home-modules/`         | `homeModules/`         |
| `legacy-packages/`      | `legacyPackages/`      |
| `nixos-configurations/` | `nixosConfigurations/` |
| `nixos-modules/`        | `nixosModules/`        |

Unchanged: `checks/`, `formatter/`, `library/`, `overlays/`, `theonecfg/`,
`secrets/`, `docs/`. `hydra-jobs/` stays kebab-case because it stops being a
flake output; keywright spells it the same way.

Removed: `packages/` (the `packages` flake output), `package-sets/` (contents
move under `overlays/`), `hydra-jobs/default.nix` (the `hydraJobs` output),
`hydra-jobs/images.nix` (absorbed by `hydra-jobs/nixos-configurations.nix`).

### Flake outputs

`flake.nix` loses `hydraJobs` and `packages`. All other outputs keep their
names; only the import paths change.

`nix build .#drduh-yubikey-guide` and similar commands keep working because
`nix` falls through to `legacyPackages.<system>.<name>` when `packages` is
absent. `nix flake check` stops evaluating those derivations; the packages
jobset covers them instead.

### Overlays

`overlays/` holds one subdirectory per overlay, and the attribute names in
`overlays/default.nix` are camelCase and spelled the same as the directory:

```
overlays/
├── default.nix
├── fixes/            # overlay.nix files, auto-discovered, composed into `fixes`
├── inputOverlays/    # <input>/overlay.nix, each takes `inputs`, exported by input name
│   └── nixvimcfg/overlay.nix
├── nixosTests/       # <test>/package.nix, exposed as pkgs.theonecfgNixosTests.<test>
│   └── yubikey-live/package.nix
└── topLevel/         # <package>/package.nix, exposed as pkgs.<package>
    ├── diceware-page/
    ├── drduh-yubikey-guide/
    ├── jellyfin-plugin-stash/
    ├── namer/
    ├── stasharr-portal/
    ├── theonecfg-bootstrap-homelab-secrets/
    ├── theonecfg-cups-brother-hll3280cdw/
    ├── theonecfg-nom-check/
    └── theonecfg-verify-hydra-jobset/
```

Exported overlay attributes: `default`, `fixes`, `nixosTests`, `topLevel`, and
one per input overlay by input name (today only `nixvimcfg`).

Individual overlays:

- `fixes`: keywright's mechanism. Every `overlay.nix` found recursively under
  `overlays/fixes/` is imported and composed with `composeManyExtensions`. The
  directory is today's `overlays/package-overrides/`, renamed; it holds only a
  `.gitkeep`. This replaces both the placeholder `fixes = final: prev: { }`
  and the `packageOverrides` attribute machinery.
- `topLevel`: `packagesFromDirectoryRecursive { inherit (final) callPackage; directory = ./topLevel; }`. **No `newScope`.** With `newScope`, the function
  wraps a `package.nix`-less directory (including the root) in `makeScope`,
  and the overlay then merges `callPackage`, `newScope`, `overrideScope`,
  `packages`, and `recurseForDerivations = true` into `pkgs`. Verified on the
  current tree, where it already bites: `nix eval .#packages.x86_64-linux`
  fails because the leaked `packages` function shadows nix's
  `legacyPackages` fallthrough. Without it, the result is a plain attribute set and
  `pkgs.callPackage` still sees every attribute every overlay adds, because
  nixpkgs defines it against the final fixpoint. Also verified.
- `nixosTests`: `theonecfgNixosTests = recurseIntoAttrs (packagesFromDirectoryRecursive { inherit (final) callPackage; directory = ./nixosTests; })`. Composed into `default`. The current reason for keeping
  it out of `default`, "so legacyPackages never loads nixos/lib", is wrong:
  evaluation is lazy and nixpkgs already exposes `nixosTests` and `testers`
  the same way. The tests need their own directory only so the packages
  jobset does not pick them up.
- `misc`: `theonecfgModulesPath = ../nixosModules;`, path updated.
- `inputOverlays/nixvimcfg/overlay.nix`: becomes a one-line addition of
  `theonecfg-nixvimcfg`. The `overrideScope` call it uses today goes away with
  the scope.
- NUR: stays inline in `default` as today.

`default` composes the same pieces in the same relative order as today, with
`packageOverrides` replaced by `fixes` and `nixosTests` added. The builder
chooses where `nixosTests` sits; nothing references it from `prev`.

### Package naming

- Third-party software keeps its upstream name: `namer`, `stasharr-portal`,
  `jellyfin-plugin-stash`, `diceware-page`, `drduh-yubikey-guide`.
- Repo-owned tools are prefixed `theonecfg-` in both directory and attribute
  name: `theonecfg-bootstrap-homelab-secrets`,
  `theonecfg-cups-brother-hll3280cdw`, `theonecfg-nom-check`,
  `theonecfg-verify-hydra-jobset`, and `theonecfg-nixvimcfg` from the input
  overlay. The prefix is the collision guard against nixpkgs.
- Existing binary names do not change. `nom-check` and
  `bootstrap-homelab-secrets` hardcode `name`; the cups driver uses its own
  `pname`. The new verify tool keeps keywright's `name = baseNameOf ./.`, so
  its binary is `theonecfg-verify-hydra-jobset`, like its attribute.
- VM tests keep bare directory names under `overlays/nixosTests/` because
  `theonecfgNixosTests` is their namespace: `pkgs.theonecfgNixosTests.yubikey-live`.
- The old `pkgs.theonecfg.*` scope and `pkgs.theonecfgTests` cease to exist.
  The two deleted verify scripts are the only packages that named themselves
  after their directory.

### Hydra jobsets

All files under `hydra-jobs/` are release-lib style: a function of
`supportedSystems`, `evalSystem`, `nixpkgs`, importing `./common.nix`,
producing `<jobname>.<system>` attributes. Each file is a candidate for one
Hydra jobset later.

| file                       | status  | jobs                                                                                                                                                                                                                                                                                                                                                                       |
| -------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `common.nix`               | edited  | drop the `extraOverlays` argument; nothing uses it once tests are in `default`                                                                                                                                                                                                                                                                                             |
| `packages.nix`             | new     | every directory name under `overlays/topLevel/`, looked up in `pkgs`, through `packagePlatforms` and `mapTestOn`; both default systems                                                                                                                                                                                                                                     |
| `vm-tests.nix`             | edited  | `mapTestOn (packagePlatforms { inherit (pkgs) theonecfgNixosTests; })`; no `extraOverlays`; still forwards its x86_64-only `supportedSystems` to `common.nix`; jobs are `theonecfgNixosTests.<test>.x86_64-linux`                                                                                                                                                          |
| `images.nix`               | deleted | its one job, the live host's ISO, becomes a branch of the type dispatch in `nixos-configurations.nix`                                                                                                                                                                                                                                                                      |
| `nixos-configurations.nix` | new     | `<host>.<system>` for every `nixosConfigurations` entry, where `<system>` is `config.nixpkgs.buildPlatform.system` and must be in `supportedSystems`. By `knownHosts` type: desktop, laptop, server: `hydraJob config.system.build.toplevel`. virtual: `hydraJob config.system.build.vm`. live: `hydraJob config.system.build.isoImage`. Any other type: `throw`, as today |
| `home-configurations.nix`  | new     | `<host>-<user>.<system>` for every `homeConfigurations` entry whose `config.nixpkgs.system` is in `supportedSystems`: `hydraJob activationPackage`                                                                                                                                                                                                                         |
| `default.nix`              | deleted | was the `hydraJobs` flake output; its dispatch moves to the two new files with the key order flipped                                                                                                                                                                                                                                                                       |

`nixos-configurations.nix` and `home-configurations.nix` do not use
`releaseLib.pkgs`; like today's `images.nix`, they take `self` and `lib` from
`common.nix` and read the flake's own configuration outputs, which carry their
per-host nixpkgs. `packages.nix` reads directory names through
`self.library.path.getDirectoryNames` (this repo spells the attribute `path`,
keywright spells it `paths`). Packages added by input overlays, such as
`theonecfg-nixvimcfg`, have no directory under `topLevel/` and are not in the
packages jobset; the home configurations that enable them build them.

### verify-hydra-jobset

`overlays/topLevel/theonecfg-verify-hydra-jobset/package.nix` is keywright's
`overlays/verification/verify-hydra-jobset/package.nix` copied verbatim.
Usage:

```sh
nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/packages.nix
nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/nixos-configurations.nix
nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/home-configurations.nix
nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/vm-tests.nix
```

It restricts `supportedSystems` to the host's system, evaluates with
`nix-eval-jobs --constituents --force-recurse`, builds everything with
`nom build --keep-going`, and exits non-zero on any evaluation error or build
failure. `theonecfg-verify-hydra-system-configs` and
`theonecfg-verify-hydra-home-configs` are deleted.

### CI

`.github/workflows/pull-request.yml` keeps the `nix flake check` job and
replaces the two verify jobs with one job per jobset file that is viable on a
free GitHub runner: packages and vm-tests. Each runs the matching
`nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/<file>.nix`. The
vm-tests job carries keywright's "Assert KVM is available" step before the
run. The existing installer and magic-nix-cache actions stay; keywright's
`nothing-but-nix` disk reclaim is added only if a job runs out of disk.

Not run in CI: `nixos-configurations.nix` and `home-configurations.nix`.
The NixOS configurations do not fit a free runner. Of the last
seven runs of today's "nix verify nixos configurations" job, six failed and
the one success took 33 minutes; the failures ran 20 to 29 minutes, building
hundreds of derivations from source and dying on an upstream build or on
Magic Nix Cache throttling. The home configurations job has been green in 5
to 7 minutes every time, but it leaves CI with the NixOS job by decision, so
that CI never builds a system or home closure. The uraninite ISO, now a job
of `nixos-configurations.nix`, is larger still. These two jobsets are for
local `verify-hydra-jobset` runs and for Hydra.
`nix flake check` still evaluates every `nixosConfigurations.<host>` toplevel,
so NixOS evaluation errors keep surfacing in CI; home configuration evaluation
does not, since `nix flake check` does not know that output.

### legacyPackages configuration

`legacyPackages/default.nix` passes `config = { allowAliases = false; allowUnfree = true; }`, matching `hydra-jobs/common.nix`. Today
`legacyPackages` passes no config, so `nix shell .#foo` and the jobsets can
disagree about what evaluates. `allowAliases = false` may surface an alias
reference in a local package or in NUR that the jobsets would also have
rejected; fix the reference, do not relax the setting.

### Documentation and references

Every reference to an old path or attribute name is updated, except in
history, which is left alone: `docs/plans/completed/`, `docs/reports/`, and
the commit subjects quoted as comments in `.git-blame-ignore-revs`. This
design and its implementation plan are also exempt, since they describe the
rename. Known locations:

- `CLAUDE.md`: the `home-modules/...` auto-import paths; the
  `nix run .#theonecfg.bootstrap-homelab-secrets` example; add the two naming
  conventions (camelCase directory after attribute, `theonecfg-` prefix for
  repo-owned packages, tests under `theonecfgNixosTests`).
- `README.md`: the architecture section headers and body; add a "Hydra CI"
  section modelled on keywright's, listing the jobset files and the verify
  command.
- `docs/README.md`: the example path.
- `docs/runbooks/migrate-zfs-host-to-impermanence-rollback.md`,
  `docs/runbooks/renew-yubikey-gpg-subkeys.md` (also
  `theonecfgTests.yubikey-live`),
  `docs/runbooks/configure-nixd-for-option-completion.md`.
- Every active plan under `docs/plans/active/` that cites an old directory
  or attribute name: 17 files today, found by the grep in verification step 7.
  Four of them cite `package-sets/top-level/...` paths that git commands in
  those plans depend on.
- Doc-comment examples in `library/default.nix` that mention `./home-modules`.
- The comment in `nixos-modules/services/pinchflat/module.nix` that cites
  `nixos-configurations/<host>/impermanence.nix`.
- The usage comment at the top of `bootstrap.sh`.
- Consumers of removed attribute paths:
  `nixos-modules/hardware/brother-hll3280cdw/module.nix`
  (`pkgs.theonecfg.cups-brother-hll3280cdw`) and
  `home-modules/programs/nixvimcfg/module.nix` (`pkgs.theonecfg.nixvimcfg`).

## Verification

Done means all of the following hold, run and observed, not inferred:

1. Before any change, from a clean checkout of the base commit rather than a
   dirty working tree, record `.drvPath` for every
   `nixosConfigurations.<host>.config.system.build.toplevel` (ISO for live
   hosts, `vm` for virtual) and every
   `homeConfigurations.<name>.activationPackage`. After, they are identical.
1. `nix flake check` passes.
1. Locally, `nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/<file>.nix`
   exits zero for `packages.nix`, `nixos-configurations.nix`,
   `home-configurations.nix`, and `vm-tests.nix`. In CI, the packages and
   vm-tests jobs are green.
1. `nix eval .#legacyPackages.x86_64-linux --apply 'p: p ? overrideScope'`
   is `false`, and `builtins.attrNames p.theonecfgNixosTests` lists the tests
   plus `recurseForDerivations` and nothing else.
1. `nix eval .#legacyPackages.x86_64-linux.theonecfg` fails with a missing
   attribute error.
1. `nix run .#theonecfg-nom-check -- --help` (or equivalent) runs the binary
   named `nom-check`.
1. `grep -rn` for `package-sets`, `theonecfgTests`, `pkgs.theonecfg.`,
   `.#theonecfg.`, `hydraJobs`, and each old kebab-case directory name returns
   hits only under `docs/plans/completed/`, `docs/reports/`,
   `.git-blame-ignore-revs`, this design, and its implementation plan.

## Decisions

Made in the brainstorm:

- Mimic keywright's architecture; Hydra will consume plain jobset files, not a
  `hydraJobs` output.
- Remove the `packages` flake output.
- Package sources live under `overlays/`.
- One naming convention for overlay outputs: camelCase, directory spelled the
  same as the attribute.
- Flatten the `theonecfg` package scope; prefix repo-owned package directories
  with `theonecfg-`.
- Drop `newScope` from `packagesFromDirectoryRecursive`.
- Fold the tests overlay into `default`; delete the `extraOverlays` plumbing.
- Keep tests nested, under `theonecfgNixosTests`.
- CI does not build NixOS or home-manager configurations; free runners cannot
  finish the NixOS job reliably.
- Live-host ISOs are jobs of `nixos-configurations.nix`, one more branch of
  the `knownHosts` type dispatch; `images.nix` is deleted.
- The verify tool is keywright's `package.nix` copied verbatim. It keeps
  `name = baseNameOf ./.`, so the binary is `theonecfg-verify-hydra-jobset`,
  the prefix rule applied all the way through.

Author's calls, reject any of them:

- No `tested` aggregate until Hydra exists.
- `verify-hydra-jobset` lives under `topLevel/` with the `theonecfg-` prefix,
  not in a keywright-style `verification/` overlay.
- NUR stays inline in `default`.
- `theonecfg-nixvimcfg` takes the prefix too, since the input is yours.
- `legacyPackages` gets `allowAliases = false; allowUnfree = true;`.
- All 17 active plans that cite old names get their paths updated; completed
  plans, reports, and `.git-blame-ignore-revs` do not.
- `nothing-but-nix` is added to CI only on evidence of disk exhaustion.
- Home configuration jobs are wrapped in `hydraJob` like everything else;
  today's `hydraJobs.homeConfigs` does not wrap them.

## Left to the builder

- Order of commits and whether to use `git mv`. Git detects renames either way.
- Exact composition order of `default`, within "same relative order as today".
- Whether `fixes` discovery uses `listFilesRecursive` filtered on
  `baseNameOf == "overlay.nix"` exactly as keywright, or an equivalent.
- The `nix-eval-jobs` memory flag for the configuration jobsets if the default
  worker limit proves too small for a full NixOS evaluation.
- Wording of the README and CLAUDE.md updates.

## Risks

- With configurations out of CI, a change that breaks a system or home
  closure build (as opposed to its evaluation) is caught only by a local
  `verify-hydra-jobset` run or, later, by Hydra. Today's CI caught those for
  home configurations and, when it finished, for NixOS.
- `getFlake "git+file://"` makes an untracked new host or package invisible
  to every jobset. Documented in README's hydra section.
- `allowAliases = false` in `legacyPackages` may break a `nix shell .#<alias>`
  habit. The fix is to use the canonical name.
- Anyone with `nix run .#theonecfg.bootstrap-homelab-secrets` in shell history
  gets a hard failure. Intended; see anti-goals.
- The `theonecfgModulesPath` store path changes name, so the `yubikey-live`
  test derivation changes. That is expected and excluded from the drvPath
  equality check, which covers configurations only.
