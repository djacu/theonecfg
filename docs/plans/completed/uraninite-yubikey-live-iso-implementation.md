# uraninite YubiKey Live ISO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `uraninite` live ISO to theonecfg, prove its profile with
a NixOS VM test that rehearses the subkey renewal, write the runbook, and
then carry out the real renewal of the three YubiKey subkeys to 2027-10-19
before they expire on 2026-10-19.

**Architecture:** Two new packages fetch drduh's guide and the diceware page
with `fetchFromGitHub`. A new profile `theonecfg.profiles.yubikey-live`
holds the air gap, the gpg configuration, the tooling and the nginx diceware
server. A thin host `nixos-configurations/uraninite/` adds the ISO image
modules and the Plasma desktop. `knownHosts` gains type `live`, which
`hydraJobs` maps to the ISO. A VM test in a separate `nixosTests` overlay, built through the
release-lib jobset `hydra-jobs/vm-tests.nix`, boots the profile
without a desktop and runs the runbook's renewal line against a throwaway
key. The ceremony itself is run by the owner on a second laptop from the
runbook.

**Tech Stack:** NixOS unstable (flake pin `c043004`, 2026-09-05), GnuPG
2.4.9, `pkgs.testers.runNixOSTest`, `installer/cd-dvd/iso-image.nix`,
Plasma 6, drduh/YubiKey-Guide `a4f662f`, grempe/diceware `9ef886a`.

**Spec:** `docs/plans/completed/uraninite-yubikey-live-iso.md`

## Global Constraints

- Branch: `djacu/uraninite-yubikey-live`, cut from `main` at `23538e3`.
- Every commit subject uses the repo's attr-path style and ends with the
  trailer `Assisted-by: Claude Code (claude-fable-5-1)`. No co-author
  trailers. Every intermediate commit must evaluate; the order here puts
  the packages before the registry and the test before the host, which
  differs from the spec's list only where nothing depends on the order.
- Run `nix fmt -- <files>` on every new or edited file; afterwards
  `git --no-pager diff --no-ext-diff --exit-code -- <those files>` must be
  clean. Always scope diffs with explicit pathspecs. `git diff` in this
  repo uses difftastic as an external diff; add `--no-ext-diff` whenever
  its output is piped or its exit code is used.
- New files must be `git add -N`'d before any `nix eval`/`nix build`, or
  the flake cannot see them.
- Verification is targeted builds, never `nix flake check`. `checks` stays
  formatting-only. The VM test and the ISO are release-lib jobset files
  built with `nix-build hydra-jobs/vm-tests.nix -A theonecfgTests.yubikey-live.x86_64-linux`
  and `nix-build hydra-jobs/images.nix -A uraninite.x86_64-linux`.
  `hydra-jobs/default.nix` is not extended beyond skipping `live` hosts.
- Package placement: `package-sets/top-level/drduh-yubikey-guide/` and
  `package-sets/top-level/diceware-page/`, exposed as
  `pkgs.drduh-yubikey-guide` and `pkgs.diceware-page`.
- `knownHosts.uraninite = { type = "live"; forwardAgent = false; }`.
- `system.stateVersion = "26.05"` on the host.
- The ISO output path is `result/iso/uraninite.iso`.
- The VM test node imports `profiles/common` and `profiles/yubikey-live`
  by path from `theonecfgModulesPath`, creates `users.users.tester`, and
  has `virtualisation.vlans = [ ]`; qemu-vm's SLiRP NIC stays as the
  stand-in for hardware and must be found `DOWN` and unaddressed. No flake
  inputs in the package scope, no desktop, default memory.
- `programs.gnupg.agent.settings` holds exactly
  `{ default-cache-ttl = 60; max-cache-ttl = 300; }`.
- The renewal line is identical in `package-sets/nixos-tests/yubikey-live/package.nix` and the
  runbook:
  `printf '%s' "$CERTIFY_PASS" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-set-expire "$KEY_FP" "$KEY_EXPIRATION" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH"`
- Key constants: `KEY_FP=6EC37842237BED45CBA6D3A58C9CFEF8EE37DA95`,
  `SUB_FP_SIGN=D41E63419DF2EBB72527F45AA574F8E664B73493`,
  `SUB_FP_ENCRYPT=73FFB33FADE8CE280ACBAA21E1B97FBD677703EC`,
  `SUB_FP_AUTH=FAC51E7D0EE7290A2D7A120BF6B7FFB11D29B9E3`,
  `KEY_EXPIRATION=2027-10-19`.
- The other five hosts' `config.system.build.toplevel.drvPath` and the five
  home configurations' `activationPackage.drvPath` must not change
  (baseline in Task 0).
- The executor never runs anything against the owner's real `~/.gnupg`,
  never plugs or probes a YubiKey, and never runs the ceremony. Tasks 8 and
  9 are the owner's; the executor prepares and checks.
- Commands the owner runs on ilmenite are fish; commands the executor runs
  through the Bash tool are bash. Each block says which.
- The executor's scratch file for this plan is
  `/tmp/claude-1000/uraninite-baseline.txt`, outside the per-session
  scratchpad on purpose: it must survive a session change.

## Review Focus

1. An empty subkey fingerprint list turns `--quick-set-expire` into its
   two-argument form and sets an expiry on the certify key, with exit 0 and
   no warning. Pinned to Task 4 step 1 (`check_expiry` asserts the `sec`
   line has an empty expiry) and the runbook's step that asserts
   `expires: never` on the certify key.
1. A system clock earlier than the newest self-signature is refused by gpg
   with `Time conflict`; a clock earlier than the key's creation is accepted
   with time-warp warnings but the signature loses silently. Neither renews.
   Pinned to Task 4 step 1 (both back-dated renewals must leave the expiry
   unchanged, the first must exit non-zero) and the runbook's clock step.
   The final review corrected the plan's earlier "silent no-op" wording.
1. A bare flag in `programs.gnupg.agent.settings` renders as `name true`
   and gpg-agent refuses to start. Pinned to Task 4 step 1
   (`gpgconf --check-options gpg-agent` and the grep for
   `enable-ssh-support`).
1. Real hardware always has NICs, so an air-gap check that demands "only
   `lo`" is wrong on the laptop and vacuous in a NIC-less VM. Pinned to
   Task 4 step 1: the SLiRP NIC must be present, `DOWN` and unaddressed.
1. The ISO file is `uraninite.iso`, no label suffix; a glob with a dash
   matches nothing and `dd` fails late. Pinned to Task 5 step 5 and the
   runbook's build step.

______________________________________________________________________

### Task 0: Baseline

**Files:** none modified.

**Interfaces:**

- Produces: `/tmp/claude-1000/uraninite-baseline.txt`, ten drvPaths that
  Task 5 compares against.

- [ ] **Step 1: Confirm a clean `main` and cut the branch (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git status --short
git rev-parse --short HEAD
git switch -c djacu/uraninite-yubikey-live
```

Expected: `git status --short` prints only
`?? docs/plans/active/uraninite-yubikey-live-iso.md` and
`?? docs/plans/active/uraninite-yubikey-live-iso-implementation.md`; HEAD is
`23538e3`.

- [ ] **Step 2: Record the baseline drvPaths (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
mkdir -p /tmp/claude-1000
{
  for h in argentite cassiterite ilmenite malachite scheelite; do
    printf 'nixos %s %s\n' "$h" "$(nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath")"
    printf 'home %s %s\n' "$h" "$(nix eval --raw ".#homeConfigurations.$h-djacu.activationPackage.drvPath")"
  done
} > /tmp/claude-1000/uraninite-baseline.txt
cat /tmp/claude-1000/uraninite-baseline.txt
```

Expected: ten lines, each ending in a `/nix/store/...drv` path.

______________________________________________________________________

### Task 1: Commit the spec and this plan

**Files:**

- Add: `docs/plans/active/uraninite-yubikey-live-iso.md` (exists, untracked)

- Add: `docs/plans/active/uraninite-yubikey-live-iso-implementation.md` (this file)

- [ ] **Step 1: Format and commit (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
nix fmt -- docs/plans/active/uraninite-yubikey-live-iso.md docs/plans/active/uraninite-yubikey-live-iso-implementation.md
git add docs/plans/active/uraninite-yubikey-live-iso.md docs/plans/active/uraninite-yubikey-live-iso-implementation.md
git commit -m "docs/plans: add uraninite yubikey live iso

Design and implementation plan for an air-gapped YubiKey live ISO and the
renewal of the GPG subkeys that expire 2026-10-19.

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 2: Packages `drduh-yubikey-guide` and `diceware-page`

**Files:**

- Create: `package-sets/top-level/drduh-yubikey-guide/package.nix`
- Create: `package-sets/top-level/diceware-page/package.nix`
- Modify: `packages/default.nix` (the `inherit` block)

**Interfaces:**

- Produces: `pkgs.drduh-yubikey-guide` with
  `$out/share/drduh-yubikey-guide/{README.md,config/,scripts/,templates/,diceware-vt.patch}`;
  `pkgs.diceware-page` with `$out/index.html`. Task 4 and Task 5 reference
  both by those paths.

- [ ] **Step 1: Write `drduh-yubikey-guide` (Write tool)**

`package-sets/top-level/drduh-yubikey-guide/package.nix`:

```nix
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
stdenvNoCC.mkDerivation {
  pname = "drduh-yubikey-guide";
  version = "0-unstable-2026-10-04";

  src = fetchFromGitHub {
    owner = "drduh";
    repo = "YubiKey-Guide";
    rev = "a4f662fb4d8bac8d424a7bcfef8dea2eb250eec7";
    hash = "sha256-zWYmVW+uwW8NcFS4LDipONyLXMui9kfEIfgHcH0CQK8=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/drduh-yubikey-guide
    cp -r README.md config scripts templates $out/share/drduh-yubikey-guide/
    cp nix/diceware-vt.patch $out/share/drduh-yubikey-guide/
    runHook postInstall
  '';

  meta = {
    description = "Guide to using YubiKey for GnuPG and SSH, with its gpg configuration files";
    homepage = "https://github.com/drduh/YubiKey-Guide";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
```

- [ ] **Step 2: Write `diceware-page` (Write tool)**

`package-sets/top-level/diceware-page/package.nix`:

```nix
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  drduh-yubikey-guide,
}:
stdenvNoCC.mkDerivation {
  pname = "diceware-page";
  version = "0-unstable-2022-10-28";

  src = fetchFromGitHub {
    owner = "grempe";
    repo = "diceware";
    rev = "9ef886a2a9699f73ae414e35755fd2edd69983c8";
    hash = "sha256-44rpK8svPoKx/e/5aj0DpEfDbKuNjroKT4XUBpiOw2g=";
  };

  # drduh's patch folds in the changes published at
  # https://secure.research.vt.edu/diceware/ (local word lists, no CDN).
  patches = [ "${drduh-yubikey-guide}/share/drduh-yubikey-guide/diceware-vt.patch" ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r . $out/
    runHook postInstall
  '';

  meta = {
    description = "Static diceware passphrase generator web page, served offline";
    homepage = "https://github.com/grempe/diceware";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
```

- [ ] **Step 3: Expose both from `packages/default.nix` (Edit tool)**

Change

```nix
mapAttrs (const (pkgs: {

  inherit (pkgs.theonecfg)
    nom-check
    ;

})) inputs.self.legacyPackages
```

to

```nix
mapAttrs (const (pkgs: {

  inherit (pkgs)
    diceware-page
    drduh-yubikey-guide
    ;

  inherit (pkgs.theonecfg)
    nom-check
    ;

})) inputs.self.legacyPackages
```

- [ ] **Step 4: Build both and inspect (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git add -N package-sets/top-level/drduh-yubikey-guide/package.nix package-sets/top-level/diceware-page/package.nix
nix fmt -- package-sets/top-level/drduh-yubikey-guide/package.nix package-sets/top-level/diceware-page/package.nix packages/default.nix
nix build --no-link --print-out-paths .#drduh-yubikey-guide .#diceware-page
G=$(nix build --no-link --print-out-paths .#drduh-yubikey-guide)
D=$(nix build --no-link --print-out-paths .#diceware-page)
ls "$G/share/drduh-yubikey-guide" "$G/share/drduh-yubikey-guide/config"
grep -c '' "$G/share/drduh-yubikey-guide/README.md"
grep -n -E '^(require-secmem|keyid-format|cert-digest-algo)' "$G/share/drduh-yubikey-guide/config/gpg.conf"
test -r "$D/index.html" && grep -c -i diceware "$D/index.html"
```

Expected: both builds succeed. The guide directory lists `README.md config diceware-vt.patch scripts templates`; config lists `dirmngr.conf gpg-agent.conf gpg.conf scdaemon.conf`; the three gpg.conf options are
present; `index.html` exists and mentions diceware. If `fetchFromGitHub`
reports a hash mismatch, the prefetch and the fetcher disagree on
normalisation: copy the `got:` hash from the error into `package.nix` and
rebuild once; do not loosen anything else.

- [ ] **Step 5: Commit (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git --no-pager diff --no-ext-diff --exit-code -- packages/default.nix package-sets/top-level/drduh-yubikey-guide/package.nix package-sets/top-level/diceware-page/package.nix || true
git add packages/default.nix package-sets/top-level/drduh-yubikey-guide/package.nix package-sets/top-level/diceware-page/package.nix
git commit -m "packages: add drduh-yubikey-guide and diceware-page

Both are fetched at build time with fetchFromGitHub so they are cacheable
and substitutable. The guide package carries drduh's README and gpg
configuration files; the diceware page is grempe's generator with drduh's
patch applied, to be served offline on the live ISO.

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 3: Registry entry, the hydra skip, and `hydra-jobs/common.nix`

**Files:**

- Modify: `theonecfg/default.nix:5-27` (the `knownHosts` set)
- Modify: `hydra-jobs/default.nix:86-90` (the `systemConfigs` filter)
- Create: `hydra-jobs/common.nix`

**Interfaces:**

- Produces: `knownHosts.uraninite.type == "live"`; `hydraJobs.systemConfigs`
  ignores `live` hosts; `import ./common.nix args` returns
  `{ lib, nixpkgs, self, releaseLib }` for the jobset files of Tasks 4 and
  5, where `releaseLib` is `pkgs/top-level/release-lib.nix` with
  `self.overlays.default` plus `args.extraOverlays` applied.

- [ ] **Step 1: Add the registry entry (Edit tool)**

In `theonecfg/default.nix`, after the `test-vm` entry inside `knownHosts`:

```nix
    test-vm = {
      type = "virtual";
      forwardAgent = false;
    };
    uraninite = {
      type = "live";
      forwardAgent = false;
    };
```

- [ ] **Step 2: Commit the registry (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
nix fmt -- theonecfg/default.nix
nix eval .#theonecfg.knownHosts.uraninite
git add theonecfg/default.nix
git commit -m "theonecfg: add uraninite to knownHosts as type live

uraninite is a live ISO, not an installed machine. forwardAgent is false
so the gpg home module writes no ssh match block for it.

Assisted-by: Claude Code (claude-fable-5-1)"
```

Expected eval output: `{ forwardAgent = false; type = "live"; }`.

- [ ] **Step 3: Skip live hosts in `hydra-jobs/default.nix` (Edit tool)**

This file is the dispatch-on-type pattern the repo is retiring; it gets no
new branch. Change the `systemConfigs` filter from

```nix
      (
        filterAttrs (const (
          value: value.config.nixpkgs.buildPlatform.system == system
        )) inputs.self.nixosConfigurations
      )
```

to

```nix
      (
        filterAttrs (
          name: value:
          # Live images are built by hydra-jobs/images.nix, a release-lib
          # jobset file; this flake-output dispatch is not extended.
          knownHosts.${name}.type != "live"
          && value.config.nixpkgs.buildPlatform.system == system
        ) inputs.self.nixosConfigurations
      )
```

- [ ] **Step 4: Check nothing else changed and commit (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
nix fmt -- hydra-jobs/default.nix
nix eval .#hydraJobs.systemConfigs.x86_64-linux.scheelite.drvPath
git add hydra-jobs/default.nix
git commit -m "hydraJobs: skip live hosts in systemConfigs

Live images are built by hydra-jobs/images.nix in the release-lib shape
used by keywright. The type dispatch here is not extended.

Assisted-by: Claude Code (claude-fable-5-1)"
```

Expected: the scheelite drvPath equals the `nixos scheelite` line in the
baseline file (hydraJob wraps the same toplevel).

- [ ] **Step 5: Write `hydra-jobs/common.nix` (Write tool)**

After keywright's `hydra-jobs/common.nix`. The `nixpkgsArgs` block is
restated in full because passing `nixpkgsArgs` replaces release-lib's
default argument wholesale, and that default is `allowAliases = false`,
`allowUnfree = false`, `inHydra = true`, `__allowFileset = false`. The block is keywright's
verbatim, `allowUnfree = true` included.

```nix
{
  # The platforms supported.
  supportedSystems ? [
    "aarch64-linux"
    "x86_64-linux"
  ],

  # The system evaluating this expression.
  evalSystem ? builtins.currentSystem or "x86_64-linux",

  # Whether to apply hydraJob to each derivation.
  scrubJobs ? true,

  # Additional overlays to apply to the package set.
  extraOverlays ? [ ],

  # The path to Nixpkgs.
  nixpkgs ? null,
}@args:
let

  # A self-reference to this flake, so a jobset file can be evaluated by
  # Hydra as a plain Nix expression and still see the flake's outputs.
  self = builtins.getFlake "git+file://${toString ../.}";

  # Default values do not make unsupplied arguments present; they only make
  # the variable available in scope.
  nixpkgs = args.nixpkgs or self.inputs.nixpkgs-unstable.outPath;

  inherit (self.inputs.nixpkgs-lib) lib;

in
{

  inherit
    lib
    nixpkgs
    self
    ;

  releaseLib = import (nixpkgs + "/pkgs/top-level/release-lib.nix") {
    inherit
      scrubJobs
      supportedSystems
      ;
    system = evalSystem;
    # Passing nixpkgsArgs replaces release-lib's default wholesale, so every
    # setting it carries is restated here.
    nixpkgsArgs = {
      # release-lib forbids lib.fileset by default (Nix issue 11503, chroot
      # stores); packages in this repo's overlay may use it.
      __allowFileset = true;
      config = {
        # By default, Nixpkgs allows aliases. Setting them to false allows us
        # to detect breakages sooner rather than later.
        allowAliases = false;
        allowUnfree = true;
        inHydra = true;
      };
      overlays = [
        self.overlays.default
      ]
      ++ extraOverlays;
    };
  };

}
```

- [ ] **Step 6: Evaluate and commit (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git add -N hydra-jobs/common.nix
nix fmt -- hydra-jobs/common.nix
nix-instantiate --eval -E '(import ./hydra-jobs/common.nix { }).releaseLib.pkgs.drduh-yubikey-guide.name'
git add hydra-jobs/common.nix
git commit -m "hydra-jobs: add common.nix after keywright

Shared setup for release-lib jobset files: a git+file self-reference to
the flake, the pinned nixpkgs-unstable, and release-lib with the default
overlay plus any extra overlays a jobset asks for.

Assisted-by: Claude Code (claude-fable-5-1)"
```

Expected: the eval prints `"drduh-yubikey-guide-0-unstable-2026-10-04"`,
proving the self-reference, the pin and the default overlay all resolve
through release-lib.

______________________________________________________________________

### Task 4: VM test, then the profile that makes it pass

The test is written first so that the profile is implemented against a
failing check. Four commits come out of this task: the profile, the
`theonecfgModulesPath` overlay, the `nixosTests` overlay with the test, and
`hydra-jobs/vm-tests.nix`.

**Files:**

- Create: `package-sets/nixos-tests/yubikey-live/package.nix`
- Modify: `overlays/default.nix` (add `misc` with `theonecfgModulesPath` to
  `default`; add the `nixosTests` overlay and export it beside `default`)
- Create: `hydra-jobs/vm-tests.nix`
- Create: `nixos-modules/profiles/yubikey-live/module.nix`

**Interfaces:**

- Consumes: `pkgs.drduh-yubikey-guide`, `pkgs.diceware-page` (Task 2),
  `hydra-jobs/common.nix` (Task 3), `nixos-modules/profiles/common/module.nix`.

- Produces: `theonecfg.profiles.yubikey-live.enable`; the
  `view-yubikey-guide` command on the system path; nginx on
  `127.0.0.1:8080`. Task 5 depends on the option and the command.

- [ ] **Step 1: Write the test (Write tool)**

`package-sets/nixos-tests/yubikey-live/package.nix`. `theonecfgModulesPath`
comes from the `misc` overlay (step 2); everything else is ordinary
`callPackage` injection.

```nix
{
  lib,
  coreutils,
  curl,
  drduh-yubikey-guide,
  gawk,
  gnupg,
  testers,
  theonecfgModulesPath,
  writeShellApplication,
}:
let

  # Rehearses the runbook's renewal against a throwaway key. The renewal line
  # below must stay identical to docs/runbooks/renew-yubikey-gpg-subkeys.md.
  rehearsal = writeShellApplication {
    name = "yubikey-live-rehearsal";
    runtimeInputs = [
      coreutils
      gawk
      gnupg
    ];
    text = ''
      export GNUPGHOME
      GNUPGHOME=$(mktemp -d)
      P=throwaway
      IDENTITY='Throwaway <throwaway@example.invalid>'

      # The key is created in the past so that the renewal below is a real
      # one: its subkeys have already expired by the time it runs, as the
      # YubiKey's would if a ceremony slipped past the date, and the clock
      # cases further down have room on both sides of the creation time.
      CREATED=20200101T000000
      gpg --batch --faked-system-time "$CREATED" --passphrase "$P" \
        --quick-gen-key "$IDENTITY" rsa2048 cert never
      KEY_FP=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^fpr:/ { print $10; exit }')

      # --batch --passphrase only takes effect together with loopback pinentry
      # (gpg(1), --passphrase: "Since Version 2.1 the --pinentry-mode also
      # needs to be set to loopback").
      for usage in sign encrypt auth; do
        gpg --batch --faked-system-time "$CREATED" --pinentry-mode loopback --passphrase "$P" \
          --quick-add-key "$KEY_FP" rsa2048 "$usage" 1d
      done

      # In --with-colons output the first fpr line belongs to the primary key;
      # the following ones are the subkeys in creation order.
      mapfile -t SUB_FPS < <(gpg -K --with-colons | awk -F: '$1 == "fpr" { if (++n > 1) print $10 }')
      SUB_FP_SIGN=''${SUB_FPS[0]}
      SUB_FP_ENCRYPT=''${SUB_FPS[1]}
      SUB_FP_AUTH=''${SUB_FPS[2]}
      KEY_EXPIRATION=$(date -d '+1 year' +%F)
      CERTIFY_PASS=$P

      # Field 7 of sec/ssb (and pub/sub) lines is the expiry in epoch seconds,
      # empty when the key never expires. The primary must stay empty: with an
      # empty subkey list --quick-set-expire silently falls back to its
      # two-argument form and sets the certify key's expiry instead.
      check_expiry() {
        awk -F: -v want="$1" '
          $1 ~ /^(sec|pub)$/ && $7 != "" { print "certify key gained an expiry"; exit 1 }
          $1 ~ /^(ssb|sub)$/ {
            n++
            if ($7 < want - 86400 || $7 > want + 86400) { print "subkey expiry " $7 " is not near " want; exit 1 }
          }
          END { if (n != 3) { print "expected 3 subkeys, saw " n; exit 1 } }'
      }
      want=$(date -d "$KEY_EXPIRATION" +%s)

      # Renewal line, verbatim from the runbook.
      printf '%s' "$CERTIFY_PASS" |
        gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
          --quick-set-expire "$KEY_FP" "$KEY_EXPIRATION" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH"
      gpg -K --with-colons | check_expiry "$want"

      # A wrong clock on the ceremony laptop has two faces, and neither
      # changes the expiry. A clock after the key's creation but before the
      # newest self-signature is refused outright: "make_keysig_packet
      # failed: Time conflict", exit 2. A clock before the key's creation is
      # accepted with "created N days in the future" warnings, but gpg keeps
      # the newest signature by creation time, so the back-dated one loses
      # silently. The runbook's gpg -K check after the renewal is what
      # catches both; prove it by trying both and asserting nothing moved.
      if printf '%s' "$CERTIFY_PASS" |
        gpg --batch --pinentry-mode loopback --passphrase-fd 0 --faked-system-time 20210101T000000 \
          --quick-set-expire "$KEY_FP" "$(date -d '+2 years' +%F)" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH"; then
        echo "a renewal dated before the newest signature must be refused" >&2
        exit 1
      fi
      gpg -K --with-colons | check_expiry "$want"
      printf '%s' "$CERTIFY_PASS" |
        gpg --batch --pinentry-mode loopback --passphrase-fd 0 --faked-system-time 20190101T000000 \
          --quick-set-expire "$KEY_FP" "$(date -d '+2 years' +%F)" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH"
      gpg -K --with-colons | check_expiry "$want"

      # keyid-format 0xlong can only come from /etc/gnupg/gpg.conf; this
      # GNUPGHOME has no gpg.conf of its own. grep -c rather than -q: -q
      # closes the pipe on the first match and the writer fails under
      # pipefail.
      gpg -k | grep -c 'rsa2048/0x' > /dev/null
      # cert-digest-algo SHA512 shows as digest algo 10 on the self-signatures.
      gpg --export "$KEY_FP" | gpg --list-packets | grep -c 'digest algo 10' > /dev/null

      # The armored export is what the daily machines import; it must carry
      # the renewal into a fresh keyring.
      asc=$(mktemp)
      gpg --armor --export "$KEY_FP" > "$asc"
      other=$(mktemp -d)
      GNUPGHOME=$other gpg --import "$asc"
      GNUPGHOME=$other gpg -k --with-colons | check_expiry "$want"
    '';
  };

in
testers.runNixOSTest {
  name = "yubikey-live";

  nodes.machine =
    { ... }:
    {
      # The flake's default NixOS module sets nixpkgs.overlays, which the test
      # framework makes read-only, and its user modules need the theonecfg
      # registry. The two profiles below need neither, so they are imported
      # by path and the node keeps the framework's pkgs, which already carry
      # this repo's overlays.
      imports = [
        "${theonecfgModulesPath}/profiles/common/module.nix"
        "${theonecfgModulesPath}/profiles/yubikey-live/module.nix"
      ];

      networking.hostName = "uraninite";
      theonecfg.profiles.yubikey-live.enable = true;

      # The ISO logs in djacu, created by the host file; the test only needs
      # some unprivileged user to run the rehearsal as.
      users.users.tester.isNormalUser = true;

      # vlans = [] removes the per-vlan NICs the framework would configure
      # with addresses. qemu-vm's unconditional SLiRP user NIC stays: it
      # stands in for the laptop's own Ethernet and Wi-Fi hardware, which the
      # air-gap check below must find present, down and unaddressed.
      virtualisation.vlans = [ ];

      environment.systemPackages = [ curl ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Air gap: hardware NICs exist on any real machine, so the property is
    # that the configuration leaves every one of them down and without an
    # address. The SLiRP NIC plays the hardware here.
    links = [line.split() for line in machine.succeed("ip -br link").splitlines() if line.strip()]
    names = [fields[0] for fields in links]
    assert "lo" in names and len(names) >= 2, f"expected lo plus a NIC: {names}"
    for fields in links:
        if fields[0] != "lo":
            assert fields[1] == "DOWN", f"interface is not down: {fields}"
    # ip -br addr prints only the name and state for an unaddressed interface.
    addressed = [line.split()[0] for line in machine.succeed("ip -br addr").splitlines() if len(line.split()) > 2]
    assert addressed == ["lo"], f"addressed interfaces: {addressed}"
    machine.fail("systemctl is-active sshd.service")
    machine.fail("systemctl is-active NetworkManager.service")
    # pcscd is socket-activated; the service only starts on the first client.
    machine.succeed("systemctl is-active pcscd.socket")
    machine.wait_for_unit("nginx.service")

    # Both configs must parse. A bare flag written into gpg-agent.conf as
    # "name true" would stop the agent from starting at all.
    machine.succeed("runuser -u tester -- env HOME=/home/tester gpgconf --check-options gpg")
    machine.succeed("runuser -u tester -- env HOME=/home/tester gpgconf --check-options gpg-agent")
    machine.fail("grep -q enable-ssh-support /etc/gnupg/gpg-agent.conf")

    machine.succeed("test -r ${drduh-yubikey-guide}/share/drduh-yubikey-guide/README.md")
    machine.succeed("command -v view-yubikey-guide")
    # grep -c reads to the end; grep -q would close the pipe on the first
    # match and curl would fail with a write error under pipefail.
    machine.succeed("curl -sf http://127.0.0.1:8080/index.html | grep -c -i diceware")

    machine.succeed("runuser -u tester -- env HOME=/home/tester ${lib.getExe rehearsal}")
  '';
}
```

- [ ] **Step 2: Add the `misc` and `nixosTests` overlays and `hydra-jobs/vm-tests.nix` (Edit and Write tools)**

In `overlays/default.nix`, extend the `lib.attrsets` inherit:

```nix
  inherit (lib.attrsets)
    attrValues
    genAttrs
    recurseIntoAttrs
    ;
```

Add two overlays in the `let` block after `inputOverlays`:

```nix
  misc = _final: _prev: {
    # This repo's counterpart of nixpkgs' modulesPath: lets a VM test import
    # a NixOS module by path without going through the flake outputs.
    theonecfgModulesPath = ../nixos-modules;
  };

  # VM tests, kept out of `default` so legacyPackages and the package jobs
  # never load nixos/lib. hydra-jobs/vm-tests.nix applies it.
  nixosTests = final: _prev: {
    theonecfgTests = recurseIntoAttrs (packagesFromDirectoryRecursive {
      inherit (final) callPackage;
      directory = ../package-sets/nixos-tests;
    });
  };
```

Change the tail of the file from

```nix
packageOverrides
// inputOverlays
// {

  default = composeManyExtensions (
    (attrValues packageOverrides)
    ++ [
      inputs.nur.overlays.default
      toplevelOverlays
      fixes
    ]
    ++ (attrValues inputOverlays)
  );

}
```

to

```nix
packageOverrides
// inputOverlays
// {

  inherit nixosTests;

  default = composeManyExtensions (
    (attrValues packageOverrides)
    ++ [
      inputs.nur.overlays.default
      toplevelOverlays
      misc
      fixes
    ]
    ++ (attrValues inputOverlays)
  );

}
```

Write `hydra-jobs/vm-tests.nix`, after keywright's:

```nix
{
  # The platforms supported. VM tests need KVM, which the builders have on
  # x86_64 only.
  supportedSystems ? [ "x86_64-linux" ],

  # The system evaluating this expression.
  evalSystem ? builtins.currentSystem or "x86_64-linux",

  # The path to Nixpkgs.
  nixpkgs ? null,
}@args:
let

  inherit
    (import ./common.nix (
      args
      // {
        extraOverlays = [ self.overlays.nixosTests ];
      }
    ))
    releaseLib
    self
    ;

  inherit (releaseLib)
    mapTestOn
    packagePlatforms
    pkgs
    ;

in
mapTestOn (packagePlatforms {
  inherit (pkgs) theonecfgTests;
})
```

- [ ] **Step 3: Run the test and watch it fail for the right reason (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git add -N package-sets/nixos-tests/yubikey-live/package.nix hydra-jobs/vm-tests.nix
nix fmt -- package-sets/nixos-tests/yubikey-live/package.nix overlays/default.nix hydra-jobs/vm-tests.nix
nix eval --raw .#legacyPackages.x86_64-linux.theonecfgModulesPath; echo
nix-instantiate --eval -E 'builtins.attrNames (import ./hydra-jobs/vm-tests.nix { }).theonecfgTests'
nix-build hydra-jobs/vm-tests.nix -A theonecfgTests.yubikey-live.x86_64-linux --no-out-link 2>&1 | tail -5
```

Expected from the first eval: a `/nix/store/...-nixos-modules` path. From
the second: `[ "yubikey-live" ]`.

Expected: evaluation fails with
`The option 'theonecfg.profiles.yubikey-live.enable' does not exist`. Any
other error is a bug in the test file; fix it before continuing.

- [ ] **Step 4: Write the profile (Write tool)**

`nixos-modules/profiles/yubikey-live/module.nix`:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkForce
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.profiles.yubikey-live;

  guide = "${pkgs.drduh-yubikey-guide}/share/drduh-yubikey-guide";

  viewYubikeyGuide = pkgs.writeShellApplication {
    name = "view-yubikey-guide";
    runtimeInputs = [ pkgs.glow ];
    text = ''
      readme=${guide}/README.md
      # Inside a desktop session hand the file to the default viewer; on a
      # console render it in the terminal.
      if [ -n "''${WAYLAND_DISPLAY:-}''${DISPLAY:-}" ] && command -v xdg-open > /dev/null; then
        exec xdg-open "$readme"
      fi
      exec glow -p "$readme"
    '';
  };

in
{

  options.theonecfg.profiles.yubikey-live.enable = mkEnableOption "theonecfg air-gapped YubiKey live profile";

  config = mkIf cfg.enable {

    theonecfg.profiles.common.enable = true;

    # Everything on this system is ephemeral; nothing on it is worth a
    # password. Which user exists and logs in is the host's decision, so
    # this profile needs neither the theonecfg registry nor a desktop.
    security.sudo.wheelNeedsPassword = false;

    services.openssh.enable = false;
    programs.ssh.startAgent = false;

    swapDevices = [ ];
    boot.tmp.cleanOnBoot = true;
    boot.kernel.sysctl."kernel.unprivileged_bpf_disabled" = 1;

    # Air gap. plasma6 enables networkmanager with mkDefault, hence mkForce.
    boot.initrd.network.enable = false;
    networking = {
      resolvconf.enable = false;
      dhcpcd.enable = false;
      dhcpcd.allowInterfaces = [ ];
      interfaces = { };
      firewall.enable = true;
      useDHCP = false;
      useNetworkd = false;
      wireless.enable = false;
      networkmanager.enable = mkForce false;
    };

    # drduh's hardened gpg.conf for every user, root included: gpg reads
    # /etc/gnupg/gpg.conf before the user's own file.
    environment.etc."gnupg/gpg.conf".source = "${guide}/config/gpg.conf";
    programs.gnupg = {
      dirmngr.enable = false;
      agent = {
        enable = true;
        enableSSHSupport = true;
        pinentryPackage = pkgs.pinentry-qt;
        # drduh's gpg-agent.conf minus enable-ssh-support: a bare flag cannot
        # be expressed in the key-value format, and enableSSHSupport already
        # provides the socket.
        settings = {
          default-cache-ttl = 60;
          max-cache-ttl = 300;
        };
      };
    };
    services.udev.packages = [ pkgs.yubikey-personalization ];

    # No shell history on disk. HISTFILE is bash's; fish stops saving when
    # fish_history is the empty string.
    environment.interactiveShellInit = "unset HISTFILE";
    programs.fish.interactiveShellInit = ''set -g fish_history ""'';

    # The diceware generator, served to the local browser only.
    services.nginx = {
      enable = true;
      virtualHosts.diceware = {
        listen = [
          {
            addr = "127.0.0.1";
            port = 8080;
          }
        ];
        root = pkgs.diceware-page;
      };
    };

    environment.systemPackages = [
      pkgs.cryptsetup
      pkgs.diceware
      pkgs.drduh-yubikey-guide
      pkgs.ent
      pkgs.glow
      pkgs.gparted
      pkgs.htop
      pkgs.paperkey
      pkgs.parted
      pkgs.pcsc-tools
      pkgs.pgpdump
      pkgs.pwgen
      pkgs.tmux
      pkgs.yubico-piv-tool
      pkgs.yubikey-manager
      pkgs.yubikey-personalization
      viewYubikeyGuide
    ];

  };

}
```

- [ ] **Step 5: Run the test until it passes (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git add -N nixos-modules/profiles/yubikey-live/module.nix
nix fmt -- nixos-modules/profiles/yubikey-live/module.nix
nix-build hydra-jobs/vm-tests.nix -A theonecfgTests.yubikey-live.x86_64-linux --no-out-link 2>&1 | tail -40
```

Expected: the build ends with the test driver's `(finished: run the VM test script ...)`
and exit 0. On failure, read the assertion that fired and fix the profile
or the test; do not weaken an assertion. For interactive debugging:

```bash
nix-build hydra-jobs/vm-tests.nix -A theonecfgTests.yubikey-live.x86_64-linux.driverInteractive -o result-driver && ./result-driver/bin/nixos-test-driver
```

then `start_all()` and `machine.shell_interact()` inside the driver.

- [ ] **Step 6: Commit the profile, the modules path, the test overlay, then the jobset (bash)**

The `misc` overlay is committed on its own with `git add -p` so that the
`nixosTests` additions in the same file land in the following commit.

```bash
cd /home/djacu/dev/djacu/theonecfg
git --no-pager diff --no-ext-diff --exit-code -- nixos-modules/profiles/yubikey-live/module.nix package-sets/nixos-tests/yubikey-live/package.nix overlays/default.nix hydra-jobs/vm-tests.nix || true
git add nixos-modules/profiles/yubikey-live/module.nix
git commit -m "nixosModules.profiles.yubikey-live: init

Air-gapped GnuPG and YubiKey tooling after drduh's YubiKey Guide: no
network, drduh's gpg.conf system-wide, pcscd, the guide and the diceware
page available offline. The profile has no image format, no desktop and no
user, so a VM test imports it by path beside profiles/common.

Assisted-by: Claude Code (claude-fable-5-1)"
git add -p overlays/default.nix   # stage only the misc overlay hunks and its entry in default
git commit -m "overlays: add theonecfgModulesPath

The repo's counterpart of nixpkgs' modulesPath, so a VM test can import a
module by path instead of threading flake inputs into the package scope.

Assisted-by: Claude Code (claude-fable-5-1)"
git add package-sets/nixos-tests/yubikey-live/package.nix overlays/default.nix
git commit -m "overlays: add the nixosTests overlay with the yubikey-live VM test

VM tests live under package-sets/nixos-tests as callPackage files and are
exposed as pkgs.theonecfgTests by an overlay kept out of default, after the
layout in keywright. The first test boots the yubikey-live profile without
a desktop, asserts the air gap and the gpg configuration, and rehearses the
subkey renewal from the runbook against a throwaway key, including the
back-dated clock case the runbook warns about.

Assisted-by: Claude Code (claude-fable-5-1)"
git add hydra-jobs/vm-tests.nix
git commit -m "hydra-jobs: add vm-tests.nix

A release-lib jobset over common.nix that applies the nixosTests overlay
and exposes pkgs.theonecfgTests per supported system, as keywright does.

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 5: Host `uraninite` and the ores row

**Files:**

- Create: `nixos-configurations/uraninite/default.nix`
- Create: `hydra-jobs/images.nix`
- Modify: `docs/reference/ores.md:37` (the `uraninite` row)

**Interfaces:**

- Consumes: `theonecfg.profiles.yubikey-live.enable` (Task 4),
  `knownHosts.uraninite`, the `live` skip and `hydra-jobs/common.nix`
  (Task 3).

- Produces: `nixosConfigurations.uraninite.config.system.build.isoImage`
  and `result/iso/uraninite.iso`. Tasks 7 to 9 use the ISO.

- [ ] **Step 1: Write the host (Write tool)**

`nixos-configurations/uraninite/default.nix`:

```nix
inputs: {
  release = rec {
    number = "unstable";
    nixpkgs = inputs."nixpkgs-${number}";
  };
  modules =
    {
      config,
      lib,
      modulesPath,
      pkgs,
      ...
    }:
    {
      imports = [
        (modulesPath + "/installer/cd-dvd/iso-image.nix")
        (modulesPath + "/profiles/all-hardware.nix")
      ];
      config = {
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "26.05";

        theonecfg.profiles.yubikey-live.enable = true;

        # iso-image.nix defines image.baseName itself at normal priority.
        image.baseName = lib.mkForce config.networking.hostName;
        isoImage = {
          squashfsCompression = "zstd";
          makeEfiBootable = true;
          makeUsbBootable = true;
          appendToMenuLabel = " YubiKey Live";
        };

        # Who logs in is the host's decision; the profile is user-agnostic
        # so the VM test can import it without the theonecfg registry.
        theonecfg.users.djacu.enable = true;
        users.users.djacu.initialHashedPassword = "";
        users.users.root.initialHashedPassword = "";

        # The desktop lives here, not in the profile, so the VM test stays a
        # console system.
        theonecfg.desktops.plasma.enable = true;
        services.displayManager.autoLogin = {
          enable = true;
          user = "djacu";
        };

        programs.firefox = {
          enable = true;
          preferences = {
            # No data-reporting prompt and no welcome tab on an offline box.
            "datareporting.policy.dataSubmissionEnabled" = false;
            "browser.aboutwelcome.enabled" = false;
          };
          preferencesStatus = "user";
        };

        environment.systemPackages = [
          pkgs.kdePackages.okular
          (pkgs.makeDesktopItem {
            name = "yubikey-guide";
            desktopName = "YubiKey Guide";
            genericName = "Guide to using YubiKey for GnuPG and SSH";
            exec = "view-yubikey-guide";
            categories = [ "Documentation" ];
          })
          (pkgs.makeDesktopItem {
            name = "diceware";
            desktopName = "Diceware Passphrase Generator";
            genericName = "Passphrase Generator";
            exec = "xdg-open http://127.0.0.1:8080/";
            categories = [ "Utility" ];
          })
        ];
      };
    };
}
```

- [ ] **Step 2: Update the ores row (Edit tool)**

In `docs/reference/ores.md` change

```
| uranium    | uraninite    | —           | —                                      | —     |
```

to

```
| uranium    | uraninite    | live ISO    | any x86_64 laptop, boots from USB      | air-gapped YubiKey/GnuPG ceremonies |
```

and let `nix fmt` re-pad the table.

- [ ] **Step 3: Write `hydra-jobs/images.nix` (Write tool)**

```nix
{
  # The platforms supported. Live images are x86_64 only today.
  supportedSystems ? [ "x86_64-linux" ],

  # The system evaluating this expression.
  evalSystem ? builtins.currentSystem or "x86_64-linux",

  # The path to Nixpkgs.
  nixpkgs ? null,
}@args:
let

  inherit (import ./common.nix args)
    lib
    self
    ;

  inherit (lib.attrsets)
    filterAttrs
    mapAttrs
    ;

  inherit (lib.customisation)
    hydraJob
    ;

  inherit (lib.lists)
    elem
    ;

  inherit (self.theonecfg)
    knownHosts
    ;

  # Every nixosConfiguration of type live whose build platform is supported.
  liveHosts = filterAttrs (
    name: value:
    knownHosts.${name}.type == "live"
    && elem value.config.nixpkgs.buildPlatform.system supportedSystems
  ) self.nixosConfigurations;

in
# Same <name>.<system> shape release-lib's mapTestOn produces.
mapAttrs (_: value: {
  ${value.config.nixpkgs.buildPlatform.system} = hydraJob value.config.system.build.isoImage;
}) liveHosts
```

- [ ] **Step 4: Evaluate the host and the jobset (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git add -N nixos-configurations/uraninite/default.nix hydra-jobs/images.nix
nix fmt -- nixos-configurations/uraninite/default.nix hydra-jobs/images.nix docs/reference/ores.md
nix eval --raw .#nixosConfigurations.uraninite.config.image.fileName; echo
nix eval .#hydraJobs.systemConfigs.x86_64-linux --apply builtins.attrNames
nix-instantiate --eval -E 'builtins.attrNames (import ./hydra-jobs/images.nix { }).uraninite'
nix-instantiate hydra-jobs/images.nix -A uraninite.x86_64-linux
```

Expected: `uraninite.iso`; a host list without `uraninite`;
`[ "x86_64-linux" ]`; a `.drv` path.

- [ ] **Step 5: Confirm the other hosts did not move (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
{
  for h in argentite cassiterite ilmenite malachite scheelite; do
    printf 'nixos %s %s\n' "$h" "$(nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath")"
    printf 'home %s %s\n' "$h" "$(nix eval --raw ".#homeConfigurations.$h-djacu.activationPackage.drvPath")"
  done
} | diff /tmp/claude-1000/uraninite-baseline.txt - && echo "baseline unchanged"
```

Expected: `baseline unchanged`. Any difference is a regression in Tasks 2
to 5; find the cause, do not accept it.

- [ ] **Step 6: Build the ISO (bash, long)**

```bash
cd /home/djacu/dev/djacu/theonecfg
nix build -L .#nixosConfigurations.uraninite.config.system.build.isoImage 2>&1 | tail -5
ls -la result/iso/
test -f result/iso/uraninite.iso && echo "iso present"
nix-build hydra-jobs/images.nix -A uraninite.x86_64-linux --no-out-link
```

Expected: `result/iso/uraninite.iso`, roughly 3 to 4 GB. The jobset build
afterwards is instant: it is the same derivation, already built. Record the
size in the task notes. `result*` is git-ignored.

- [ ] **Step 7: Commit the host, the jobset, then the ores row (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git --no-pager diff --no-ext-diff --exit-code -- nixos-configurations/uraninite/default.nix hydra-jobs/images.nix docs/reference/ores.md || true
git add nixos-configurations/uraninite/default.nix
git commit -m "nixosConfigurations.uraninite: init

A live ISO: the yubikey-live profile plus the ISO image modules, the djacu
user and the Plasma desktop with autologin.

Assisted-by: Claude Code (claude-fable-5-1)"
git add hydra-jobs/images.nix
git commit -m "hydra-jobs: add images.nix for live hosts

A release-lib shaped jobset over common.nix that builds the isoImage of
every knownHosts entry of type live. hydra-jobs/default.nix skips those
hosts and is not extended.

Assisted-by: Claude Code (claude-fable-5-1)"
git add docs/reference/ores.md
git commit -m "docs/reference/ores.md: assign uraninite to the live ISO

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 6: Runbook

**Files:**

- Create: `docs/runbooks/renew-yubikey-gpg-subkeys.md`

**Interfaces:**

- Consumes: the renewal line and key constants from Global Constraints;
  `result/iso/uraninite.iso` (Task 5).

- Produces: the procedure Tasks 7 to 9 follow.

- [ ] **Step 1: Write the runbook (Write tool)**

`docs/runbooks/renew-yubikey-gpg-subkeys.md`:

````markdown
# Renew the YubiKey GPG subkeys

Push the expiry of the three subkeys on the YubiKey forward using the
offline certify key, on an air-gapped laptop booted from the `uraninite`
live ISO. Nothing is written to the YubiKey; subkey expiry lives in
self-signatures on the public key.

The VM test `theonecfgTests.yubikey-live` (`hydra-jobs/vm-tests.nix`) runs
the renewal line below against a throwaway key. Keep the two identical.

## Prerequisites

- A build host with this repo (ilmenite) and three USB sticks: one for the
  ISO (4 GB or more), the backup stick (a single LUKS partition holding a
  `GNUPGHOME` directory: `gnupg` from the original provisioning, and a
  `<date>-renewed` copy after each renewal), and an empty transfer stick.
- The certify key passphrase.
- A second laptop that boots x86_64 UEFI media with Secure Boot turned
  off.
- The current key, for reference:
  - certify `0x8C9CFEF8EE37DA95`, fingerprint
    `6EC37842237BED45CBA6D3A58C9CFEF8EE37DA95`, never expires
  - sign `0xA574F8E664B73493`, `D41E63419DF2EBB72527F45AA574F8E664B73493`
  - encrypt `0xE1B97FBD677703EC`, `73FFB33FADE8CE280ACBAA21E1B97FBD677703EC`
  - auth `0xF6B7FFB11D29B9E3`, `FAC51E7D0EE7290A2D7A120BF6B7FFB11D29B9E3`

Parameters you set: the new expiry date, the three USB device names, and
the name of the newest backup directory.

## Procedure

### 1. Build and flash the ISO (ilmenite, fish)

```fish
cd ~/dev/djacu/theonecfg
nix build .#nixosConfigurations.uraninite.config.system.build.isoImage
lsblk
```

Confirm the ISO stick's device, then, with `sdX` replaced:

```fish
sudo dd if=result/iso/uraninite.iso of=/dev/sdX bs=4M status=progress oflag=sync
sudo cmp -n (stat -c %s result/iso/uraninite.iso) result/iso/uraninite.iso /dev/sdX; and echo flash verified
```

The ISO file is `uraninite.iso` exactly, no version suffix.

### 2. Prepare the transfer stick (ilmenite, fish)

Plug in the empty transfer stick, `lsblk`, confirm its device `sdY`, then:

```fish
sudo mkfs.vfat -n GPGPUBLIC /dev/sdY
```

Whole device, no partition table. It will carry only the public key.

### 3. Boot the ceremony laptop

Boot from the ISO stick with Secure Boot off. Plasma logs in as `djacu`
without a prompt. Open a terminal and start `bash`; the login shell is fish
and the commands below are bash.

```bash
bash
ip -br link
ip -br addr
systemctl is-active pcscd.socket
date
```

`ip -br link` lists `lo` and the laptop's own network hardware; every
interface other than `lo` must show `DOWN`. `ip -br addr` must show
addresses on `lo` only. The configuration never brings an interface up;
the hardware existing is expected. The YubiKey is not needed and can stay
at home. If `date` is wrong, set it before going on:

```bash
sudo date -s 'YYYY-MM-DD HH:MM'
```

A wrong clock has two faces, and neither renews anything. A clock after
the key's creation (2025-10-19) but before the newest signature (the date
in the committed `.asc` file name) is refused with
`make_keysig_packet failed: Time conflict`. A clock before 2025-10-19 is
accepted with "created N days in the future" warnings, but gpg keeps the
newest signature by creation time, so the back-dated one loses silently.
Step 7's `gpg -K` is the check that catches both.

### 4. Mount the backup and transfer sticks

Plug in the backup stick, find its partition with `lsblk`, then with `sdX1`
replaced:

```bash
sudo cryptsetup luksOpen /dev/sdX1 gnupg-secrets
sudo mkdir -p /mnt/encrypted-storage /mnt/public
sudo mount /dev/mapper/gnupg-secrets /mnt/encrypted-storage
ls /mnt/encrypted-storage
```

Plug in the transfer stick:

```bash
sudo mount /dev/disk/by-label/GPGPUBLIC /mnt/public
```

### 5. Copy the certify key into a temporary GNUPGHOME

Pick the directory from the `ls` above that holds the keyring and put its
name in `BACKUP`: `gnupg` on the first renewal, the newest
`<date>-renewed` afterwards:

```bash
BACKUP=gnupg
export GNUPGHOME
GNUPGHOME=$(mktemp -d)
sudo cp -av "/mnt/encrypted-storage/$BACKUP/." "$GNUPGHOME"/
sudo chown -R djacu "$GNUPGHOME"
rm -f "$GNUPGHOME"/gpg-agent.conf
gpg -K
```

The `rm` drops any agent config saved with the backup so the live system's
own applies. `gpg -K` must show `sec` (not `sec#`) for `0x8C9CFEF8EE37DA95`
and the three subkeys.

### 6. Set the variables

```bash
export KEY_FP=6EC37842237BED45CBA6D3A58C9CFEF8EE37DA95
export SUB_FP_SIGN=D41E63419DF2EBB72527F45AA574F8E664B73493
export SUB_FP_ENCRYPT=73FFB33FADE8CE280ACBAA21E1B97FBD677703EC
export SUB_FP_AUTH=FAC51E7D0EE7290A2D7A120BF6B7FFB11D29B9E3
export KEY_EXPIRATION=2027-10-19
read -rs CERTIFY_PASS; export CERTIFY_PASS
```

The fingerprints are written out on purpose. The guide derives them with an
`awk` pipeline; if that pipeline yields nothing, `--quick-set-expire` falls
back to its two-argument form and sets an expiry on the certify key, with
exit 0 and no warning.

### 7. Renew

```bash
printf '%s' "$CERTIFY_PASS" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-set-expire "$KEY_FP" "$KEY_EXPIRATION" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH"
gpg -K
```

Stop unless all three subkeys show `expires:` with the date you put in
`KEY_EXPIRATION` and the certify key still shows no expiry.

### 8. Export and update the backup

```bash
gpg --armor --export "$KEY_FP" | sudo tee "/mnt/public/8C9CFEF8EE37DA95-$(date +%F).asc" > /dev/null
sudo cp -av "$GNUPGHOME" "/mnt/encrypted-storage/$(date +%Y.%m.%d)-renewed"
```

The export is named by its export date, as drduh's guide names it, so the
file says how fresh its signatures are. It contains public material only.
The copy gives next year's
renewal a starting point with the current signatures; the original backup
directory is never modified.

### 9. Close down

```bash
unset CERTIFY_PASS
sudo umount /mnt/public /mnt/encrypted-storage
sudo cryptsetup luksClose gnupg-secrets
```

Power off. The temporary directory is on tmpfs and dies with it. The backup
stick goes back to storage; only the transfer stick travels.

### 10. Import on ilmenite (fish)

Plug in the transfer stick:

```fish
sudo mkdir -p /mnt/public
sudo mount /dev/disk/by-label/GPGPUBLIC /mnt/public
gpg --import /mnt/public/8C9CFEF8EE37DA95-*.asc
gpg -K
```

The three card-backed subkeys show the new expiry. No agent restart is
needed. If `gpg -K` lists no subkeys at all, gpg-agent has lost its card
stubs; insert the YubiKey and run `gpg --card-status`, then look again.

### 11. Update the repo (ilmenite, fish)

Set `new` to the exact file name section 8 wrote. The ISO clock is UTC, so
the date in the name can be the day after the local ceremony date. Do not
glob it: the transfer stick may carry an older export too, and a
two-element `new` would write both names into the module.

```fish
cd ~/dev/djacu/theonecfg
git switch -c djacu/gpg-renewal-(date +%Y)
set new 8C9CFEF8EE37DA95-YYYY-MM-DD.asc
test -f /mnt/public/$new; or echo "no such file on the transfer stick"
git rm home-modules/users/djacu/programs/gpg/8C9CFEF8EE37DA95-*.asc
cp /mnt/public/$new home-modules/users/djacu/programs/gpg/$new
sed -i "s|source = ./8C9CFEF8EE37DA95-.*\\.asc;|source = ./$new;|" home-modules/users/djacu/programs/gpg/module.nix
sudo umount /mnt/public
git add home-modules/users/djacu/programs/gpg
git diff --cached --stat
home-manager switch --flake .#ilmenite-djacu
gpg -k 0x8C9CFEF8EE37DA95
git commit
```

`git diff --cached --stat` must show one file removed, one added, and
`module.nix` changed by one line. Commit subject:
`homeModules.users.djacu.programs.gpg: renew subkeys to <KEY_EXPIRATION>`.
Open the PR and merge it.

### 12. The other hosts

On argentite, cassiterite, malachite and scheelite, after pulling `main`:

```fish
home-manager switch --flake .#(hostname)-djacu
gpg -k 0x8C9CFEF8EE37DA95
```

Each shows the new expiry on the subkeys. home-manager re-imports the
committed public key on every switch.

### 13. GitHub

Settings, SSH and GPG keys: remove the GPG key `8C9CFEF8EE37DA95` and add
the contents of the new `.asc`. GitHub keeps the Verified status of commits
from the record made when they were first verified, so older commits stay
Verified.

## Post-ceremony checks

```fish
cd ~/dev/djacu/theonecfg
git commit --allow-empty -m "test: signed commit after renewal"
git log -1 --show-signature
```

`Good signature`. Push a branch and check the Verified badge on that commit
and on a commit from before the renewal. Delete the test branch afterwards.

## Known gotchas

- The login shell on the ISO is fish; the ceremony commands are bash. Run
  `bash` first.
- `--quick-set-expire` needs the certify key's fingerprint as its first
  argument; a key id is rejected.
- `--batch --passphrase-fd 0` only works with `--pinentry-mode loopback`.
- The backup `GNUPGHOME` may contain a `gpg-agent.conf` from the machine
  that created it; the runbook removes it after the copy.
- The ISO has no NTP. Check the clock.
- Next year, pick the `-renewed` directory as `BACKUP`; the 2025 directory
  carries the old signatures.
- `require-secmem` in gpg.conf makes gpg refuse to run if memory locking
  fails. If it does: `ulimit -l unlimited` in the ceremony shell.
- A commit failing with `Unusable secret key` on a daily machine is usually
  missing card stubs, not expiry: `gpg --card-status` with the key
  inserted.

## Recovery

- A failed `--quick-set-expire` changes nothing; fix the cause and re-run
  it.
- A wrong or damaged `.asc` on the online side: re-export from the backup
  stick; the ceremony can be repeated, it only adds signatures.
- An incomplete `-renewed` copy: delete that directory on the LUKS volume
  and copy again. Never touch the original dated directory.
- If `gpg -K` on the ceremony laptop shows `sec#`, the backup directory
  does not hold the secret certify key; try another directory before
  anything else.
```

Confirm the ISO stick's device, then, with `sdX` replaced:

```fish
sudo dd if=result/iso/uraninite.iso of=/dev/sdX bs=4M status=progress oflag=sync
sudo cmp -n (stat -c %s result/iso/uraninite.iso) result/iso/uraninite.iso /dev/sdX; and echo flash verified
```

The ISO file is `uraninite.iso` exactly, no version suffix.

### 2. Prepare the transfer stick (ilmenite, fish)

Plug in the empty transfer stick, `lsblk`, confirm its device `sdY`, then:

```fish
sudo mkfs.vfat -n GPGPUBLIC /dev/sdY
```

Whole device, no partition table. It will carry only the public key.

### 3. Boot the ceremony laptop

Boot from the ISO stick with Secure Boot off. Plasma logs in as `djacu`
without a prompt. Open a terminal and start `bash`; the login shell is fish
and the commands below are bash.

```bash
bash
ip -br link
ip -br addr
systemctl is-active pcscd.socket
date
```

`ip -br link` lists `lo` and the laptop's own network hardware; every
interface other than `lo` must show `DOWN`. `ip -br addr` must show
addresses on `lo` only. The configuration never brings an interface up;
the hardware existing is expected. The YubiKey is not needed and can stay
at home. If `date` is wrong, set it before going on:

```bash
sudo date -s 'YYYY-MM-DD HH:MM'
```

A clock earlier than the existing signatures (2025-10-19 or any later
renewal) makes the renewal a silent no-op: gpg keeps the newest signature
by creation time and reports nothing.

### 4. Mount the backup and transfer sticks

Plug in the backup stick, find its partition with `lsblk`, then with `sdX1`
replaced:

```bash
sudo cryptsetup luksOpen /dev/sdX1 gnupg-secrets
sudo mkdir -p /mnt/encrypted-storage /mnt/public
sudo mount /dev/mapper/gnupg-secrets /mnt/encrypted-storage
ls /mnt/encrypted-storage
```

Plug in the transfer stick:

```bash
sudo mount /dev/disk/by-label/GPGPUBLIC /mnt/public
```

### 5. Copy the certify key into a temporary GNUPGHOME

Pick the directory from the `ls` above that holds the keyring and put its
name in `BACKUP`: `gnupg` on the first renewal, the newest
`<date>-renewed` afterwards:

```bash
BACKUP=gnupg
export GNUPGHOME
GNUPGHOME=$(mktemp -d)
sudo cp -av "/mnt/encrypted-storage/$BACKUP/." "$GNUPGHOME"/
sudo chown -R djacu "$GNUPGHOME"
rm -f "$GNUPGHOME"/gpg-agent.conf
gpg -K
```

The `rm` drops any agent config saved with the backup so the live system's
own applies. `gpg -K` must show `sec` (not `sec#`) for `0x8C9CFEF8EE37DA95`
and the three subkeys.

### 6. Set the variables

```bash
export KEY_FP=6EC37842237BED45CBA6D3A58C9CFEF8EE37DA95
export SUB_FP_SIGN=D41E63419DF2EBB72527F45AA574F8E664B73493
export SUB_FP_ENCRYPT=73FFB33FADE8CE280ACBAA21E1B97FBD677703EC
export SUB_FP_AUTH=FAC51E7D0EE7290A2D7A120BF6B7FFB11D29B9E3
export KEY_EXPIRATION=2027-10-19
read -rs CERTIFY_PASS; export CERTIFY_PASS
```

The fingerprints are written out on purpose. The guide derives them with an
`awk` pipeline; if that pipeline yields nothing, `--quick-set-expire` falls
back to its two-argument form and sets an expiry on the certify key, with
exit 0 and no warning.

### 7. Renew

```bash
printf '%s' "$CERTIFY_PASS" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-set-expire "$KEY_FP" "$KEY_EXPIRATION" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH"
gpg -K
```

Stop unless all three subkeys show `expires: 2027-10-19` and the certify key
still shows no expiry.

### 8. Export and update the backup

```bash
gpg --armor --export "$KEY_FP" | sudo tee "/mnt/public/8C9CFEF8EE37DA95-$(date +%F).asc" > /dev/null
sudo cp -av "$GNUPGHOME" "/mnt/encrypted-storage/$(date +%Y.%m.%d)-renewed"
```

The export is named by its export date, as drduh's guide names it, so the
file says how fresh its signatures are. It contains public material only.
The copy gives next year's
renewal a starting point with the current signatures; the original backup
directory is never modified.

### 9. Close down

```bash
unset CERTIFY_PASS
sudo umount /mnt/public /mnt/encrypted-storage
sudo cryptsetup luksClose gnupg-secrets
```

Power off. The temporary directory is on tmpfs and dies with it. The backup
stick goes back to storage; only the transfer stick travels.

### 10. Import on ilmenite (fish)

Plug in the transfer stick:

```fish
sudo mkdir -p /mnt/public
sudo mount /dev/disk/by-label/GPGPUBLIC /mnt/public
gpg --import /mnt/public/8C9CFEF8EE37DA95-*.asc
gpg -K
```

The three card-backed subkeys show the new expiry. No agent restart is
needed. If `gpg -K` lists no subkeys at all, gpg-agent has lost its card
stubs; insert the YubiKey and run `gpg --card-status`, then look again.

### 11. Update the repo (ilmenite, fish)

```fish
cd ~/dev/djacu/theonecfg
git switch -c djacu/gpg-renewal-(date +%Y)
set new (basename /mnt/public/8C9CFEF8EE37DA95-*.asc)
git rm home-modules/users/djacu/programs/gpg/8C9CFEF8EE37DA95-*.asc
cp /mnt/public/$new home-modules/users/djacu/programs/gpg/$new
sed -i "s|source = ./8C9CFEF8EE37DA95-.*\\.asc;|source = ./$new;|" home-modules/users/djacu/programs/gpg/module.nix
sudo umount /mnt/public
git add home-modules/users/djacu/programs/gpg
git diff --cached --stat
home-manager switch --flake .#ilmenite-djacu
gpg -k 0x8C9CFEF8EE37DA95
git commit
```

Commit subject:
`homeModules.users.djacu.programs.gpg: renew subkeys to 2027-10-19`. Open
the PR and merge it.

### 12. The other hosts

On argentite, cassiterite, malachite and scheelite, after pulling `main`:

```fish
home-manager switch --flake .#(hostname)-djacu
gpg -k 0x8C9CFEF8EE37DA95
```

Each shows `expires: 2027-10-19` on the subkeys. home-manager re-imports
the committed public key on every switch.

### 13. GitHub

Settings, SSH and GPG keys: remove the GPG key `8C9CFEF8EE37DA95` and add
the contents of the new `.asc`. GitHub keeps the Verified status of commits
from the record made when they were first verified, so older commits stay
Verified.

## Post-ceremony checks

```fish
cd ~/dev/djacu/theonecfg
git commit --allow-empty -m "test: signed commit after renewal"
git log -1 --show-signature
```

`Good signature`. Push a branch and check the Verified badge on that commit
and on a commit from before the renewal. Delete the test branch afterwards.

## Known gotchas

- The login shell on the ISO is fish; the ceremony commands are bash. Run
  `bash` first.
- `--quick-set-expire` needs the certify key's fingerprint as its first
  argument; a key id is rejected.
- `--batch --passphrase-fd 0` only works with `--pinentry-mode loopback`.
- The backup `GNUPGHOME` may contain a `gpg-agent.conf` from the machine
  that created it; the runbook removes it after the copy.
- The ISO has no NTP. Check the clock.
- Next year, pick the `-renewed` directory as `BACKUP`; the 2025 directory
  carries the old signatures.
- `require-secmem` in gpg.conf makes gpg refuse to run if memory locking
  fails. If it does: `ulimit -l unlimited` in the ceremony shell.
- A commit failing with `Unusable secret key` on a daily machine is usually
  missing card stubs, not expiry: `gpg --card-status` with the key
  inserted.

## Recovery

- A failed `--quick-set-expire` changes nothing; fix the cause and re-run
  it.
- A wrong or damaged `.asc` on the online side: re-export from the backup
  stick; the ceremony can be repeated, it only adds signatures.
- An incomplete `-renewed` copy: delete that directory on the LUKS volume
  and copy again. Never touch the original dated directory.
- If `gpg -K` on the ceremony laptop shows `sec#`, the backup directory
  does not hold the secret certify key; try another directory before
  anything else.
````

- [ ] **Step 2: Format and commit (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git add -N docs/runbooks/renew-yubikey-gpg-subkeys.md
nix fmt -- docs/runbooks/renew-yubikey-gpg-subkeys.md
grep -c 'quick-set-expire "\$KEY_FP" "\$KEY_EXPIRATION" "\$SUB_FP_SIGN" "\$SUB_FP_ENCRYPT" "\$SUB_FP_AUTH"' docs/runbooks/renew-yubikey-gpg-subkeys.md package-sets/nixos-tests/yubikey-live/package.nix
nix build --no-link .#checks.x86_64-linux.formatting
git add docs/runbooks/renew-yubikey-gpg-subkeys.md
git commit -m "docs/runbooks: add renew-yubikey-gpg-subkeys

Assisted-by: Claude Code (claude-fable-5-1)"
```

Expected: the grep reports 1 match in the runbook and 2 in the test (the
real and the back-dated run). The renewal line is byte-identical in both.

______________________________________________________________________

### Task 7: Boot the real ISO in QEMU

**Files:** none.

**Interfaces:**

- Consumes: `result/iso/uraninite.iso` from Task 5.

- Produces: the owner's confirmation that the image boots and the desktop
  pieces work; corrections go back into Task 5 or Task 4 as new commits.

- [ ] **Step 1: Owner boots the ISO (ilmenite, fish)**

```fish
cd ~/dev/djacu/theonecfg
nix shell .#qemu .#OVMF --command qemu-system-x86_64 -enable-kvm -m 4G -cpu host -bios (nix build --print-out-paths --no-link .#OVMF.fd)/FV/OVMF.fd -cdrom result/iso/uraninite.iso
```

If `.#OVMF.fd` does not resolve, use
`-drive if=pflash,format=raw,readonly=on,file=(nix eval --raw .#OVMF.fd)/FV/OVMF_CODE.fd`
instead of `-bios`.

- [ ] **Step 2: Owner checks, executor records (fish inside the VM)**

Check in order and report each:

1. The boot menu shows an entry ending in `YubiKey Live`.
1. Plasma comes up logged in as `djacu`, no password prompt.
1. In a terminal: `ip -br link` shows every non-`lo` interface `DOWN` and
   `ip -br addr` shows addresses on `lo` only.
1. The launcher shows `YubiKey Guide` and opens the README in a window.
1. The launcher shows `Diceware Passphrase Generator` and Firefox opens
   the page with no first-run tab and no blocking network error.
1. In a terminal, `bash`, then
   `GNUPGHOME=(mktemp -d) gpg --quick-gen-key test rsa2048 cert never`
   pops a pinentry-qt window (cancel it). Desktop sanity only; the
   ceremony uses loopback and never shows a prompt.

Anything that fails is fixed in the host file or the profile, with the VM
test re-run for profile changes, and committed with an attr-path subject
before Task 8.

______________________________________________________________________

### Task 8: Flash, boot the ceremony laptop, check the card path

Owner's task, from the runbook sections 1 to 3.

- [ ] **Step 1: Flash and verify (runbook section 1)**
- [ ] **Step 2: Format the transfer stick (runbook section 2)**
- [ ] **Step 3: Boot the laptop, confirm the air gap and the clock (runbook section 3)**
- [ ] **Step 4: Once, with the YubiKey inserted: `gpg --card-status` lists the card**

This proves the CCID path on that machine. Remove the YubiKey afterwards;
the ceremony does not use it.

______________________________________________________________________

### Task 9: The ceremony and the follow-through

Owner's task, from the runbook sections 4 to 13 and the post-ceremony
checks. The executor's part is the repo update in section 11 after the
owner has imported the key on ilmenite: it diffs the replaced `.asc`
(`git --no-pager diff --no-ext-diff --stat`, expecting only the one file),
checks that `gpg --show-keys --with-subkey-fingerprint` on the new file
reports `expires: 2027-10-19` on all three subkeys and no expiry on the
primary, and commits with the subject from the runbook.

- [ ] **Step 1: Sections 4 to 9 on the ceremony laptop**
- [ ] **Step 2: Section 10, import on ilmenite**
- [ ] **Step 3: Section 11, repo update, commit, PR, merge**
- [ ] **Step 4: Section 12, the other four hosts**
- [ ] **Step 5: Section 13, GitHub**
- [ ] **Step 6: Post-ceremony checks, including the older commit still Verified**

______________________________________________________________________

### Task 10: Close the plan

**Files:**

- Move: `docs/plans/active/uraninite-yubikey-live-iso.md` to
  `docs/plans/completed/`

- Move: `docs/plans/active/uraninite-yubikey-live-iso-implementation.md`
  to `docs/plans/completed/`

- [ ] **Step 1: Update the status lines and move (bash)**

Set the spec's `**Status:**` line to
`Completed <date>; subkeys renewed to 2027-10-19, verified on GitHub` and
fold any runbook corrections made during the ceremony into the spec's
section 6. Then:

```bash
cd /home/djacu/dev/djacu/theonecfg
git mv docs/plans/active/uraninite-yubikey-live-iso.md docs/plans/completed/
git mv docs/plans/active/uraninite-yubikey-live-iso-implementation.md docs/plans/completed/
nix fmt -- docs/plans/completed/uraninite-yubikey-live-iso.md docs/plans/completed/uraninite-yubikey-live-iso-implementation.md
git add docs/plans
git commit -m "docs/plans: complete uraninite yubikey live iso

Assisted-by: Claude Code (claude-fable-5-1)"
```

- [ ] **Step 2: Open the PR for the branch (bash)**

```bash
cd /home/djacu/dev/djacu/theonecfg
git push -u origin djacu/uraninite-yubikey-live
```

The PR description lists the commits' subjects and ends with
`Assisted-by: Claude Code (claude-fable-5-1)`. The owner opens it (gh is
not authenticated on ilmenite).
