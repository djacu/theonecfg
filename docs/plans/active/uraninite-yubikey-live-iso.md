# Plan: uraninite — air-gapped YubiKey live ISO and GPG subkey renewal

**Status:** Design, revised after adversarial review, awaiting approval
**Started:** 2026-10-11
**Owner:** djacu
**Deadline:** the current subkeys expire 2026-10-19

## Summary

Add a sixth NixOS configuration, `uraninite`, that builds not a system closure
but a bootable live ISO: an air-gapped Plasma 6 desktop with the GnuPG and
YubiKey tooling from drduh's YubiKey Guide, carrying the guide itself and the
diceware passphrase generator offline. It replaces building drduh's own
`nix/flake.nix`, which hard-codes xfce, lightdm, nixpkgs 26.05 and a bash-only
shell init, with a configuration that follows this repository's profile,
overlay and package-set conventions and pins its upstream sources with
build-time fetchers.

The first use is a key ceremony: boot the ISO on a second laptop, unlock the
LUKS backup of the offline certify key, push the expiry of the three YubiKey
subkeys from 2026-10-19 to 2027-10-19, export the refreshed public key, then
import it on the daily machines, replace the copy committed in this
repository and re-upload it to GitHub. The YubiKey is not written to; subkey
expiry lives in self-signatures on the public key, and the card holds only
private material.

A runbook records the rebuild, flash and ceremony so that next October is a
copy-paste job. A console-only NixOS VM test rehearses the ceremony with a throwaway key
and is built on demand.

## Decisions

| Decision                     | Choice                                                                                                                                                                                                                    | Why                                                                                                                                                                                                                                                                                                                      |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Build from                   | our own configuration in this repo, not drduh's flake                                                                                                                                                                     | drduh's module fights every override (xfce, lightdm, 26.05, bash init); ours reuses `profiles.common`, `desktops.plasma`, `users.djacu` and the overlay                                                                                                                                                                  |
| Where the content lives      | `theonecfg.profiles.yubikey-live`, a new profile module; the host file stays thin                                                                                                                                         | every other host puts reusable behaviour in a profile and keeps hardware in the host dir; nothing here is hardware-specific                                                                                                                                                                                              |
| Profile vs host split        | the profile is the air gap, gpg, tooling and the diceware server; the host file owns the image format and the desktop                                                                                                     | a VM test boots with the kernel passed to QEMU and the host store over 9p, so `iso-image.nix` on the test node would be inert, and a desktop would add build time and nothing to test; keeping both out of the profile keeps the test node honest and small                                                              |
| Host name                    | `uraninite`                                                                                                                                                                                                               | an unused ore from `docs/reference/ores.md`; uranium ore for the one machine that is handled with gloves on                                                                                                                                                                                                              |
| Registry type                | new `knownHosts` type `live`, `forwardAgent = false`                                                                                                                                                                      | `live` names the role, as `virtual` does, so a sibling host shipped as a raw disk image would keep the type; the unmerged `arm-custom-iso` branch used `iso`, rejected because it names the format the host file already owns; `forwardAgent = false` keeps the host out of the ssh config the gpg home module generates |
| Hydra                        | `hydra-jobs/default.nix` only learns to skip `live` hosts; the ISO and the VM test are release-lib jobset files `hydra-jobs/images.nix` and `hydra-jobs/vm-tests.nix` over a new `hydra-jobs/common.nix`, after keywright | `default.nix` is a pattern to retire, not extend; its migration is a separate plan; the 3 to 4 GB ISO cost on Hydra is accepted; keywright already runs VM tests on the same Hydra, so KVM is there                                                                                                                      |
| Release                      | `nixpkgs-unstable`                                                                                                                                                                                                        | same as every host; overlays and custom packages target it                                                                                                                                                                                                                                                               |
| Upstream sources             | `fetchFromGitHub` inside packages under `package-sets/top-level/`                                                                                                                                                         | flake inputs are for Nix expressions only; fetcher outputs are derivations, so they are buildable, cacheable and substitutable, a `flake = false` input is none of those                                                                                                                                                 |
| Package placement            | top-level `pkgs.drduh-yubikey-guide` and `pkgs.diceware-page`, not under `pkgs.theonecfg`                                                                                                                                 | the observed rule: `package-sets/top-level/` holds third-party software (`namer`, `stasharr-portal`), `theonecfg/` holds repo-owned tools; these two are third-party content                                                                                                                                             |
| Desktop                      | Plasma 6 on Wayland via `theonecfg.desktops.plasma`, sddm autologin, enabled by the host file and absent from the VM test node                                                                                            | the user's daily desktop; the module already exists; sddm honours the generic `services.displayManager.autoLogin`                                                                                                                                                                                                        |
| User                         | `djacu` via `theonecfg.users.djacu`, empty password, passwordless sudo, root password empty                                                                                                                               | fish, uid 1000 and wheel come for free; the authorized ssh key it adds is inert because sshd is off; same trust model as drduh's `nixos` user                                                                                                                                                                            |
| gpg configuration            | drduh's `gpg.conf` installed system-wide at `/etc/gnupg/gpg.conf`; `gpg-agent.conf` via `programs.gnupg.agent.settings`, pinentry-qt                                                                                      | gpg 2.4.9 opens `/etc/gnupg/gpg.conf` before the user file (verified with strace); no ephemeral `GNUPGHOME` dance, home is already on the tmpfs overlay; pinentry-qt matches the gpg home module and Plasma                                                                                                              |
| Diceware                     | included: the grempe page with drduh's VT patch, served by nginx on `127.0.0.1:8080`, Firefox to open it                                                                                                                  | completeness for future ceremonies that generate passphrases; the page is a second overlay package                                                                                                                                                                                                                       |
| Dropped from drduh's list    | cfssl, rng-tools, yubioath-flutter                                                                                                                                                                                        | not used by any GnuPG or YubiKey OpenPGP step in the guide; rng-tools is moot on a 6.x kernel                                                                                                                                                                                                                            |
| New expiry                   | 2027-10-19, one year                                                                                                                                                                                                      | same cadence as the original keys; the runbook makes the repeat cheap                                                                                                                                                                                                                                                    |
| Renew, not rotate            | renew                                                                                                                                                                                                                     | keeps the subkeys, so nothing encrypted or any SSH authorized key changes; the guide's renewal flow applies directly to the LUKS backup layout in use                                                                                                                                                                    |
| Subkey selection             | the three subkey fingerprints are written literally in the runbook; the guide's `awk` pipeline is not used                                                                                                                | an empty pipeline result degrades `--quick-set-expire` to its two-argument form and sets an expiry on the certify key (verified); a stray key in the backup makes it fail; `*` skips already-expired subkeys                                                                                                             |
| Public key file in this repo | replaced in place, filename unchanged                                                                                                                                                                                     | the module references the name and the date in it is the key creation date, which does not change                                                                                                                                                                                                                        |
| Public key transport         | a separate plain FAT stick, the transfer stick, formatted on ilmenite beforehand; the renewed `.asc` is written to it on the air-gapped laptop and read on ilmenite                                                       | the backup sticks carry a single LUKS partition and nothing else, so the guide's "public partition" does not exist here; the backup sticks never touch an online machine                                                                                                                                                 |
| Rehearsal                    | a console-only NixOS VM test in a separate `nixosTests` overlay, after the keywright layout, scripts the ceremony with a throwaway key; `checks` stays formatting-only                                                    | proves the runbook commands end to end and keeps proving them after every pin bump; the real key is used exactly once; `nix flake check` is serial and slow, so verification uses targeted builds                                                                                                                        |
| Real ISO boot                | booted by hand in QEMU and on the laptop                                                                                                                                                                                  | the VM test cannot see EFI/USB boot, squashfs, Plasma rendering, pinentry-qt or CCID. An automated ISO boot test exists as a pattern (`nixos/tests/boot.nix`) but needs a second, instrumented ISO build per check; deferred to follow-ups                                                                               |

## Verified facts the design depends on

Checked at the flake pin (nixpkgs-unstable `c043004d1c6985732bcc1cbc5a9c9aecbbb4e0f0`,
2026-09-05), home-manager-unstable `2c0350c`, and drduh/YubiKey-Guide
`a4f662fb4d8bac8d424a7bcfef8dea2eb250eec7` (the local clone at
`~/dev/drduh/YubiKey-Guide`, identical to upstream `main`). Re-verify after a
pin bump. Items marked (review) were established by the adversarial review on
2026-10-11 and re-checked against the source or the manual.

- `nixos/modules/installer/cd-dvd/iso-image.nix` declares
  `isoImage.squashfsCompression`, `isoImage.makeEfiBootable`,
  `isoImage.makeUsbBootable`, `isoImage.appendToMenuLabel`, and sets
  `image.baseName` itself at normal priority (line 1034), so a host name needs
  `lib.mkForce`. `image.fileName` is then `${baseName}.iso`, so the output is
  `result/iso/uraninite.iso` with no label suffix (review). It does not import
  `profiles/installation-device.nix`, so no `nixos` user is created and
  `users.djacu` does not collide.
- `nixos/modules/programs/gnupg.nix` exposes `programs.gnupg.agent.settings`
  (writes `/etc/gnupg/gpg-agent.conf` through `pkgs.formats.keyValue` with a
  space separator) and `programs.gnupg.agent.pinentryPackage`, which sets
  `pinentry-program` in those settings. A bare flag such as
  `enable-ssh-support` cannot be expressed: `true` renders as
  `enable-ssh-support true`, which gpg-agent rejects with `argument not expected` (review). Only the two numeric TTLs go into `settings`;
  `enableSSHSupport = true` already provides the SSH socket.
- `gpg` 2.4.9 (the pinned GnuPG) opens `/etc/gnupg/gpg.conf` before
  `$GNUPGHOME/gpg.conf`, also for a non-default `GNUPGHOME` (strace on
  ilmenite, 2026-10-11). gpg-agent likewise reads `/etc/gnupg/gpg-agent.conf`
  before the user file, and a user file wins on conflict (review).
- `gpgconf --list-options gpg` does not list `cert-digest-algo` or
  `keyid-format` at all (checked on ilmenite), so the test must observe
  behaviour: `gpg -k` printing `0x`-prefixed long ids, and `--list-packets`
  on an export showing `digest algo 10` (SHA512) on the self-signature.
- `pkgs.testers.runNixOSTest` sets `node.pkgs`, which defaults
  `node.pkgsReadOnly` to true and makes `nixpkgs.overlays` a unique-typed
  option; `nixos-modules/default.nix` defines `nixpkgs.overlays` and its
  children take `theonecfg` as a module argument (review, confirmed by
  eval). That is why the test node imports `profiles/common` and
  `profiles/yubikey-live` by path instead of the flake's default module:
  neither touches `nixpkgs.overlays` or needs the registry.
- `builtins.getFlake "git+file://<repo>"` under impure evaluation sees
  modified tracked files and intent-to-add files (checked with a scratch
  repo on 2026-10-11), so `git add -N` is enough for `nix-build` of a
  release-lib jobfile to pick up new files. `pkgs/top-level/release-lib.nix`
  at the pin exposes `mapTestOn`, `packagePlatforms` and `pkgs`, takes
  `nixpkgsArgs` for overlays, and `mapTestOn (packagePlatforms { x = ...; })`
  yields `x.<name>.<system>`.
- The test driver's backdoor (`nixos/modules/testing/test-instrumentation.nix`)
  is a root shell on the virtio console `/dev/hvc0`; it needs no network.
  `virtualisation.vlans = [ ]` removes only the per-vlan NICs;
  `qemu-vm.nix` adds a SLiRP NIC (`-net nic,netdev=user.0`) unconditionally
  through `virtualisation.qemu.networkingOptions`, which must be forced to
  `[ ]` for the node to have only `lo` (review, confirmed by eval). In execution a bare `[ ]` turned out to summon QEMU's own default user NIC, and the owner's QEMU boot of the real ISO showed `ens3` as real hardware will; the air-gap property was restated as "every interface except `lo` is DOWN and only `lo` has an address", and the test keeps the SLiRP NIC as the stand-in for hardware.
- `qemu-vm.nix` defaults `virtualisation.memorySize` to 1024 MiB and
  `test-instrumentation.nix` sets `vm.panic_on_oom = 2`, which is one reason
  the test node carries no desktop (review).
- `test-instrumentation.nix` sets `users.users.root.hashedPasswordFile`; a
  profile-level `root.initialHashedPassword` produces a users-groups warning
  in the test eval, so the root password lives in the host file (review).
- `lib.mkImageMediaOverride` is priority 60 and `lib.mkVMOverride` is 10, so
  `iso-image.nix` and `qemu-vm.nix` compose rather than conflict (review);
  `nixos/tests/boot.nix` boots an instrumented `isoImage` with `-cdrom` and
  OVMF under the test framework.
- `services/display-managers/sddm.nix` reads `services.displayManager.autoLogin`
  for its `[Autologin]` section; `plasma6.nix` sets `defaultSession` to
  `plasma` by default, so the autologin session resolves.
- `environment.interactiveShellInit` reaches fish through `fenv`; `unset HISTFILE` is a bash concern only. fish 4.8.1: `fish_history` set to the
  empty string disables saving history (review).
- All of `yubikey-manager yubikey-personalization yubico-piv-tool paperkey pgpdump ent diceware pwgen pcsc-tools glow kdePackages.okular gparted cryptsetup parted tmux htop pinentry-qt` evaluate in the pinned
  `legacyPackages.x86_64-linux`.
- `lib.filesystem.packagesFromDirectoryRecursive` at the pin gives each
  directory a scope chained to its parent, so `diceware-page` taking
  `drduh-yubikey-guide` from `callPackage` resolves whether both sit at
  top-level or under `theonecfg/` (review).
- `lib.customisation.hydraJob` accepts `system.build.isoImage` (an ordinary
  `mkDerivation`). `nix flake check` evaluates `hydraJobs` and every
  `nixosConfigurations.*.config.system.build.toplevel`, so it exercises the
  `live` branch; `--apply builtins.attrNames` on `hydraJobs.systemConfigs`
  is lazy and proves nothing (review).
- drduh's repo at the pin has `config/{gpg,gpg-agent,scdaemon,dirmngr}.conf`,
  `README.md` with sections "Updating keys" and "Renew Subkeys", and
  `nix/diceware-vt.patch`. `gpg.conf` contains `require-secmem`, which makes
  gpg refuse to run if `mlock` fails; `throw-keyids` affects only encrypted
  messages. `gpg-agent.conf` has no `no-allow-loopback-pinentry` and nothing
  tty-bound; loopback works under it (review).
- Source hashes:
  - drduh/YubiKey-Guide `a4f662f…`: `sha256-zWYmVW+uwW8NcFS4LDipONyLXMui9kfEIfgHcH0CQK8=`
  - grempe/diceware `9ef886a…`: `sha256-44rpK8svPoKx/e/5aj0DpEfDbKuNjroKT4XUBpiOw2g=`
- The current key, from `gpg --show-keys --with-subkey-fingerprint` on the
  committed `.asc`: certify `0x8C9CFEF8EE37DA95`, fingerprint
  `6EC37842237BED45CBA6D3A58C9CFEF8EE37DA95`, no expiry, secret offline
  (`sec#`). Subkeys, all expiring 2026-10-19:
  - sign `0xA574F8E664B73493`, `D41E63419DF2EBB72527F45AA574F8E664B73493`
  - encrypt `0xE1B97FBD677703EC`, `73FFB33FADE8CE280ACBAA21E1B97FBD677703EC`
  - auth `0xF6B7FFB11D29B9E3`, `FAC51E7D0EE7290A2D7A120BF6B7FFB11D29B9E3`
- The home module imports that file with trust 5 and git signs with
  `0x8C9CFEF8EE37DA95`. home-manager's `programs.gpg.publicKeys` with the
  default `mutableKeys = true` runs `gpg --import` and the trust edit on
  every activation, so a replaced `.asc` is re-imported on each host's next
  `home-manager switch` (review). `--import` merges new binding signatures
  into an entry whose secret parts are card stubs and leaves
  `private-keys-v1.d` byte-identical (review, verified with a simulated
  daily keyring).
- `--quick-set-expire fpr expire subfprs...` with a fingerprint list sets
  only the named subkeys and leaves the certify key's expiry untouched; with
  two arguments it sets the primary key's expiry; the first argument must be
  a fingerprint, a key id is rejected (gpg manual, and review by test).
  `--quick-add-key` under `--batch --passphrase` needs `--pinentry-mode loopback` or fails with `No pinentry` (gpg manual, review).
- gpg selects the newest self-signature by creation time. Renewing with a
  system clock earlier than the existing signatures produces signatures that
  lose, and both the ceremony keyring and the daily keyring keep showing the
  old expiry with no error (review, verified with `--faked-system-time`).
  The live ISO has no NTP, so the clock is checked before signing.
- The ilmenite commit failure of 2026-10-10 was missing gpg-agent key stubs,
  fixed by `gpg --card-status`; unrelated to expiry but worth a line in the
  runbook.

## Non-goals

- Rotating (replacing) the subkeys. Renewal only.
- Provisioning a new YubiKey, or resetting the current one.
- Any change to the gpg home module beyond the replaced `.asc`.
- An aarch64 ISO. `nixpkgs.hostPlatform` is `x86_64-linux`; the other laptop
  is x86_64.
- Secure Boot signing of the ISO. Secure Boot is turned off on the target
  laptop for the ceremony.
- Adding `uraninite` to `home-configurations`. No home-manager on the ISO.

## Design

### 1. Registry, hydra and host (`theonecfg/default.nix`, `hydra-jobs/`, `nixos-configurations/uraninite/`)

`knownHosts.uraninite = { type = "live"; forwardAgent = false; }`.

`hydra-jobs/default.nix` is the pattern this repo is moving away from: a
flake output that dispatches on `knownHosts` types and throws on unknown
ones. It is not extended. Its `systemConfigs` filter learns to skip hosts of
type `live`, with a comment pointing at `hydra-jobs/images.nix`, and that is
the only change to it. The registry entry and the skip land before the host
directory exists, or evaluation fails mid-series.

The ISO and the VM test are built the way keywright builds its jobs:
standalone release-lib jobset files under `hydra-jobs/` that Hydra
evaluates as plain Nix expressions and that `nix-build` evaluates locally.

- `hydra-jobs/common.nix`, after keywright's: takes `supportedSystems`,
  `evalSystem`, `scrubJobs`, `extraOverlays` and `nixpkgs`; self-references
  the flake with `builtins.getFlake "git+file://${toString ../.}"`; returns
  `lib`, `nixpkgs` (default `self.inputs.nixpkgs-unstable.outPath`), `self`
  and `releaseLib`, the latter `pkgs/top-level/release-lib.nix` instantiated
  with keywright's full `nixpkgsArgs` block verbatim (`__allowFileset = true`,
  `allowAliases = false`, `allowUnfree = true`, `inHydra = true`, the
  overlays) because passing `nixpkgsArgs` replaces release-lib's defaults
  wholesale.
- `hydra-jobs/images.nix`: `supportedSystems` defaults to
  `[ "x86_64-linux" ]`; maps every `nixosConfigurations` entry whose
  `knownHosts` type is `live` and whose build platform is supported to
  `{ <system> = hydraJob config.system.build.isoImage; }`, giving the
  release-lib shape `uraninite.x86_64-linux`.
- Local build: `nix-build hydra-jobs/images.nix -A uraninite.x86_64-linux --no-out-link`.
  `nix-build` is impure, which `getFlake` on a `git+file://` ref needs;
  modified tracked files and intent-to-add files are visible through it
  (verified).
- Migrating `homeConfigs` and `systemConfigs` out of `default.nix` into this
  shape is a follow-up plan, not this one.

`nixos-configurations/uraninite/default.nix` follows `test-vm`:
`release.number = "unstable"`, `nixpkgs.hostPlatform = "x86_64-linux"`,
`system.stateVersion = "26.05"` (the current stable release, matching
ilmenite which was initialised on the same pin), enables
`theonecfg.profiles.yubikey-live`, and owns everything about the image
format, which the VM test must not see:

- imports `${modulesPath}/installer/cd-dvd/iso-image.nix` and
  `${modulesPath}/profiles/all-hardware.nix`
- `image.baseName = mkForce config.networking.hostName`
- `isoImage.squashfsCompression = "zstd"`, `makeEfiBootable = true`,
  `makeUsbBootable = true`, `appendToMenuLabel = " YubiKey Live"`
- `users.users.root.initialHashedPassword = ""` (here and not in the
  profile, so the VM test does not warn about two root password sources)

The host file also owns who logs in and the desktop, neither of which the
VM test needs:

- `theonecfg.users.djacu.enable = true`;
  `users.users.djacu.initialHashedPassword = ""`. The user module needs
  the `theonecfg` registry, which the test node does not carry, so the
  profile stays user-agnostic.
- `theonecfg.desktops.plasma.enable = true`;
  `services.displayManager.autoLogin = { enable = true; user = "djacu"; }`
- `programs.firefox.enable = true` with the two drduh preferences that
  silence the welcome tab and data-reporting prompt
- two `makeDesktopItem` launchers in `environment.systemPackages`: one for
  `view-yubikey-guide` under category Documentation, one that runs
  `xdg-open http://127.0.0.1:8080/` for the diceware page
- `kdePackages.okular` for reading the guide as a document

The `networking.hostName` assertion is satisfied by the registry entry.

`docs/reference/ores.md` gets `uranium | uraninite | live ISO | any x86_64 laptop, boots from USB | air-gapped YubiKey/GnuPG ceremonies`.

### 2. Profile (`nixos-modules/profiles/yubikey-live/module.nix`, new)

Standard skeleton: `options.theonecfg.profiles.yubikey-live.enable = mkEnableOption ...`, `config = mkIf cfg.enable { ... }`. Auto-imported by
`nixos-modules/default.nix`. The profile knows nothing about ISOs,
desktops or users, and references no option outside nixpkgs and
`profiles/common`, so the VM test imports it by path with nothing but
`profiles/common` beside it.

System:

- `swapDevices = [ ]`, `boot.tmp.cleanOnBoot = true`,
  `boot.kernel.sysctl."kernel.unprivileged_bpf_disabled" = 1`

Reuse of existing modules:

- `theonecfg.profiles.common.enable = true` for flakes, pcscd, locale and
  `caps:swapescape`; `services.openssh.enable = false` (plain, since common
  uses `mkDefault`; a `mkForce` would also defeat the test framework's
  optional ssh backdoor for interactive debugging).
- `security.sudo.wheelNeedsPassword = false`. No user is created here; the
  host does that (section 1).

Air gap, drduh's block verbatim; `mkForce` on networkmanager is kept
because plasma6, enabled by the host, sets it with `mkDefault true`:

```nix
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
```

GnuPG:

- `environment.etc."gnupg/gpg.conf".source = "${pkgs.drduh-yubikey-guide}/share/drduh-yubikey-guide/config/gpg.conf"`
- `programs.gnupg = { dirmngr.enable = false; agent = { enable = true; enableSSHSupport = true; pinentryPackage = pkgs.pinentry-qt; settings = { default-cache-ttl = 60; max-cache-ttl = 300; }; }; }`
- `programs.ssh.startAgent = false`
- `services.udev.packages = [ pkgs.yubikey-personalization ]`
- `environment.interactiveShellInit = "unset HISTFILE"` and
  `programs.fish.interactiveShellInit = "set -g fish_history \"\""` so neither
  shell writes history.

Packages (`environment.systemPackages`): `paperkey pgpdump parted gparted cryptsetup yubikey-manager yubikey-personalization yubico-piv-tool ent diceware pwgen pcsc-tools tmux htop glow drduh-yubikey-guide` plus `view-yubikey-guide` below.

Guide and diceware, usable from a console:

- `view-yubikey-guide`, a `writeShellApplication` that opens the README with
  `xdg-open` when a desktop is running and with `glow -p` otherwise.
- `services.nginx` with one virtual host listening on the literal
  `127.0.0.1`, port 8080, root `pkgs.diceware-page`. The browser and the
  launchers are the host's concern (section 1).

### 3. Packages (`package-sets/top-level/`, picked up by the overlay)

`drduh-yubikey-guide/package.nix`: `stdenv.mkDerivation` with
`src = fetchFromGitHub { owner = "drduh"; repo = "YubiKey-Guide"; rev = "a4f662fb4d8bac8d424a7bcfef8dea2eb250eec7"; hash = "sha256-zWYm…"; }`,
`version = "0-unstable-2026-10-04"`, no build, `installPhase` copies
`README.md`, `config/`, `scripts/`, `templates/` and `nix/diceware-vt.patch`
to `$out/share/drduh-yubikey-guide/`. `meta.license = lib.licenses.mit`.

`diceware-page/package.nix`: `stdenv.mkDerivation` with `src = fetchFromGitHub { owner = "grempe"; repo = "diceware"; rev = "9ef886a2a9699f73ae414e35755fd2edd69983c8"; hash = "sha256-44rp…"; }`,
`patches = [ "${drduh-yubikey-guide}/share/drduh-yubikey-guide/diceware-vt.patch" ]`,
`installPhase` copies the tree to `$out`. Takes `drduh-yubikey-guide` from
`callPackage`.

Both are exposed by `packages/default.nix` with `inherit (pkgs) drduh-yubikey-guide diceware-page` next to the existing `nom-check` line, so
`nix build .#drduh-yubikey-guide` works. `nix flake check` evaluates them
without fetching; the ISO job on Hydra builds them transitively.

### 4. NixOS VM test (`package-sets/nixos-tests/yubikey-live/package.nix`, new; `overlays/default.nix` and `hydra-jobs/vm-tests.nix`)

The layout follows the keywright repo (`overlays/default.nix` and
`hydra-jobs/vm-tests.nix` there): VM tests are `package.nix` files that
take `testers` from `callPackage`, a separate overlay `nixosTests` exposes
them as `pkgs.theonecfgTests.<name>` through
`recurseIntoAttrs (packagesFromDirectoryRecursive ...)`, and that overlay
stays out of `overlays.default` so `legacyPackages` and the package jobs
never load `nixos/lib`. `checks` stays formatting-only.

- `overlays/default.nix` gains a `misc` overlay in `default` with
  `theonecfgModulesPath = ../nixos-modules;`, the local counterpart of
  nixpkgs' `modulesPath` (keywright's commented `projectNameRepoRoot` is the
  same idea). A test imports the modules it needs by path from it, so no
  flake input or special argument reaches the package scope.
- `overlays/default.nix` also gains `nixosTests = final: _prev: { theonecfgTests = recurseIntoAttrs (packagesFromDirectoryRecursive { inherit (final) callPackage; directory = ../package-sets/nixos-tests; }); };`
  exported next to `default`, not inside it.
- `hydra-jobs/vm-tests.nix`, after keywright's: `supportedSystems` defaults
  to `[ "x86_64-linux" ]`, imports `common.nix` with
  `extraOverlays = [ self.overlays.nixosTests ]`, and returns
  `mapTestOn (packagePlatforms { inherit (pkgs) theonecfgTests; })`, giving
  `theonecfgTests.yubikey-live.x86_64-linux`. x86_64 only: the VM tests
  need KVM, which keywright's tests already get from the same Hydra.
- Local build: `nix-build hydra-jobs/vm-tests.nix -A theonecfgTests.yubikey-live.x86_64-linux --no-out-link`
  (interactively: the same with `.driverInteractive` appended and an
  out-link, then `./result/bin/nixos-test-driver`). The test needs
  `/dev/kvm`; without it the framework falls back to TCG.

The file carries comments for the non-obvious only: why the modules are
imported by path, why the SLiRP NIC must be forced away, why `--pinentry-mode loopback`
appears on the key generation calls, why the `sec` line must still have an
empty expiry, what `digest algo 10` in the packet dump means, and what the
`with-colons` field positions are. Nothing explains what a line visibly
does.

One node, `machine`, in `testers.runNixOSTest { ... }`:

- `imports = [ "${theonecfgModulesPath}/profiles/common/module.nix" "${theonecfgModulesPath}/profiles/yubikey-live/module.nix" ]`,
  `theonecfg.profiles.yubikey-live.enable = true`,
  `networking.hostName = "uraninite"`. Neither module sets
  `nixpkgs.overlays`, so the node keeps the framework's read-only `pkgs`,
  which already carries both overlays and therefore `drduh-yubikey-guide`.
- `users.users.tester = { isNormalUser = true; }`, the user the rehearsal
  runs as; the real ISO logs in `djacu`, which the host file creates.
- `virtualisation.vlans = [ ]`, so the framework configures no addressed
  NIC; qemu-vm's SLiRP user NIC stays as the stand-in for the laptop's own
  hardware, which the air-gap assertions must find present, `DOWN` and
  unaddressed
- default memory and cores; the node is a console system with nginx and
  gpg, nothing heavier

The node does not import `iso-image.nix` or enable a desktop; the image
format and the desktop are checked by booting the real ISO (section 7).

The script, in order:

1. `wait_for_unit("multi-user.target")`.

1. Air gap: `ip -br link` lists `lo` plus at least one NIC and every non-`lo`
   interface is `DOWN`; `ip -br addr` shows addresses on `lo` only;
   `systemctl is-active sshd` fails;
   `systemctl is-active NetworkManager` fails; `systemctl is-active pcscd`
   succeeds; `systemctl is-active nginx` succeeds.

1. gpg config parses: `gpgconf --check-options gpg` as `djacu` exits 0.
   Its effect is observed in step 6.

1. Offline material: the README exists at the store path of
   `drduh-yubikey-guide` interpolated into the script, and
   `curl -sf http://127.0.0.1:8080/index.html` contains the string
   `Diceware`.

1. Rehearsal of the ceremony with a throwaway key, as `tester`, in a fresh
   `GNUPGHOME`, with `P` a throwaway passphrase and `IDENTITY` a throwaway
   uid:

   ```
   gpg --batch --passphrase "$P" --quick-gen-key "$IDENTITY" rsa2048 cert never
   FP=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^fpr:/ { print $10; exit }')
   gpg --batch --pinentry-mode loopback --passphrase "$P" --quick-add-key "$FP" rsa2048 sign 1d
   gpg --batch --pinentry-mode loopback --passphrase "$P" --quick-add-key "$FP" rsa2048 encrypt 1d
   gpg --batch --pinentry-mode loopback --passphrase "$P" --quick-add-key "$FP" rsa2048 auth 1d
   ```

   then the three subkey fingerprints are read from `gpg -K --with-colons`
   (every `fpr` line after the first), and the runbook's renewal line is run
   verbatim with `KEY_FP=$FP`, `KEY_EXPIRATION` one year ahead, and those
   three fingerprints:

   ```
   printf '%s' "$CERTIFY_PASS" |
     gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
         --quick-set-expire "$KEY_FP" "$KEY_EXPIRATION" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH"
   ```

   Assertions: `gpg -K --with-colons` shows the new expiry on all three
   `ssb` lines and an empty expiry field on the `sec` line; `gpg -k` prints
   `0x`-prefixed long key ids (`keyid-format` from `/etc/gnupg/gpg.conf`);
   `gpg --export "$FP" | gpg --list-packets` shows `digest algo 10` on the
   new binding signatures (`cert-digest-algo SHA512`); the armored export
   imports into a second fresh `GNUPGHOME` without error and lists the same
   expiry. Any drift between the runbook and the test is a bug in one of
   them.

What the test deliberately does not cover: EFI and USB boot, squashfs
layout, Plasma, autologin, Firefox, pinentry-qt, YubiKey over CCID. Those
are the manual checks in section 7.

### 5. Documentation

- This file is the spec. It moves to `docs/plans/completed/` with the
  result recorded when the ceremony is done. A companion
  `uraninite-yubikey-live-iso-implementation.md` in the "For agentic
  workers" format of the existing precedents is written next, after this
  spec is approved.
- `docs/runbooks/renew-yubikey-gpg-subkeys.md`, in the shape of the existing
  runbooks: Prerequisites, Procedure (build, flash, boot checks, the
  ceremony, the import on every daily machine, the repo update, the GitHub
  re-upload), Post-ceremony checks, Known gotchas (card stubs and
  `gpg --card-status`, fish vs bash, the backup directory glob, a stale
  `gpg-agent.conf` in the backup, the clock), and Recovery (a failed
  `--quick-set-expire` changes nothing and can be re-run; a bad `.asc` on
  the online side is replaced by re-exporting; an incomplete `-renewed`
  copy is deleted and re-copied; the previous backup directory is never
  modified). Every command is literal and parameterised by the new expiry
  date, the three USB devices (ISO stick, backup stick, transfer stick), and
  the name of the newest backup directory.
- `docs/reference/ores.md` row as above.

### 6. The ceremony (the runbook's core)

On ilmenite:

1. `nix build .#nixosConfigurations.uraninite.config.system.build.isoImage`
1. `lsblk`, confirm the stick, then
   `sudo dd if=result/iso/uraninite.iso of=/dev/sdX bs=4M status=progress oflag=sync`.
1. Read-back: `sudo cmp -n "$(stat -c %s result/iso/uraninite.iso)" result/iso/uraninite.iso /dev/sdX`
   prints nothing.
1. Transfer stick: a third, empty stick, `lsblk`, confirm the device, then
   `sudo mkfs.vfat -n GPGPUBLIC /dev/sdY` (whole device, no partition
   table). It carries only the public key.

On the ceremony laptop, booted from the ISO stick with Secure Boot off, in
`bash` (fish is the login shell):

1. `ip -br link` shows every non-`lo` interface `DOWN` and `ip -br addr`
   shows addresses on `lo` only; `systemctl is-active pcscd.socket` is
   `active`.
   `gpg --card-status` is not needed and the YubiKey can stay at home.

1. Clock: `date` shows today's real date. If the RTC is wrong, `sudo date -s 'YYYY-MM-DD HH:MM'`.
   A clock earlier than 2025-10-19 makes the renewal a silent no-op.

1. Plug in the backup stick, a single LUKS partition. `lsblk` to find it,
   `sudo cryptsetup luksOpen /dev/sdX1 gnupg-secrets`, mount
   `/dev/mapper/gnupg-secrets` at `/mnt/encrypted-storage`.

1. Plug in the transfer stick, mount `/dev/disk/by-label/GPGPUBLIC` at
   `/mnt/public`.

1. `ls /mnt/encrypted-storage` and pick the newest dated directory, `BACKUP`.
   `export GNUPGHOME=$(mktemp -d)`, `sudo cp -av "/mnt/encrypted-storage/$BACKUP/." "$GNUPGHOME"/ && sudo chown -R djacu "$GNUPGHOME"`,
   `rm -f "$GNUPGHOME"/gpg-agent.conf` so the system agent config applies,
   `gpg -K` shows the certify key with secret present (`sec`, not `sec#`).

1. Set the variables, all literal in the runbook:

   ```
   export KEY_FP=6EC37842237BED45CBA6D3A58C9CFEF8EE37DA95
   export SUB_FP_SIGN=D41E63419DF2EBB72527F45AA574F8E664B73493
   export SUB_FP_ENCRYPT=73FFB33FADE8CE280ACBAA21E1B97FBD677703EC
   export SUB_FP_AUTH=FAC51E7D0EE7290A2D7A120BF6B7FFB11D29B9E3
   export KEY_EXPIRATION=2027-10-19
   read -rs CERTIFY_PASS; export CERTIFY_PASS
   ```

1. The renewal line from section 4, verbatim.

1. `gpg -K` shows `expires: 2027-10-19` on all three subkeys and `expires: never`
   on the certify key. Stop if either is not the case.

1. `gpg --armor --export "$KEY_FP" | sudo tee /mnt/public/8C9CFEF8EE37DA95-2025-10-19.asc > /dev/null`

1. `sudo cp -av "$GNUPGHOME" "/mnt/encrypted-storage/$(date +%Y.%m.%d)-renewed"`
   so the next renewal starts from the current self-signatures.

1. `unset CERTIFY_PASS`, unmount both, `sudo cryptsetup luksClose gnupg-secrets`,
   power off. The temp dir dies with the tmpfs. The backup stick goes back
   to storage; only the transfer stick travels.

On ilmenite again:

1. Plug in the transfer stick, mount it, `gpg --import` the
   `.asc`; `gpg -K` shows the new expiry on the card-backed subkeys. No
   agent restart is needed. If `gpg -K` shows no subkeys at all, run
   `gpg --card-status` with the YubiKey inserted (the 2026-10-10 stub issue).
1. Replace `home-modules/users/djacu/programs/gpg/8C9CFEF8EE37DA95-2025-10-19.asc`,
   `home-manager switch`, commit on a branch, PR, merge.
1. On argentite, cassiterite, malachite and scheelite: pull `main`,
   `home-manager switch`, `gpg -k 0x8C9CFEF8EE37DA95` shows `expires: 2027-10-19`.
1. GitHub settings, SSH and GPG keys: remove the old key, add the new export.
   The key ID is unchanged.
1. A signed commit, `git log -1 --show-signature`, the Verified badge on it,
   and the Verified badge still present on a commit signed before the
   renewal.

### 7. Verification and acceptance

Automated, on ilmenite, as targeted builds rather than `nix flake check`,
which is serial and slow:

- `nix build .#checks.x86_64-linux.formatting` passes.
- `nix-build hydra-jobs/vm-tests.nix -A theonecfgTests.yubikey-live.x86_64-linux --no-out-link`
  passes: the VM test from section 4, which covers the air gap, services,
  gpg config, offline material, and the scripted ceremony rehearsal.
- `nix build .#drduh-yubikey-guide .#diceware-page` builds both packages.
- `nix eval .#hydraJobs.systemConfigs.x86_64-linux --apply builtins.attrNames`
  does not list `uraninite`, and
  `nix-build hydra-jobs/images.nix -A uraninite.x86_64-linux --no-out-link`
  builds the ISO through the jobset file.
- `nix build .#nixosConfigurations.uraninite.config.system.build.isoImage`
  produces `result/iso/uraninite.iso`.
- The other five hosts' `config.system.build.toplevel.drvPath` values are
  unchanged against a baseline taken before the branch.

Manual, in QEMU on ilmenite with the built ISO (`qemu-system-x86_64 -enable-kvm -m 4G -bios OVMF -cdrom result/iso/uraninite.iso`), covering
what the VM test cannot:

- The EFI boot menu shows the `YubiKey Live` label and boots to Plasma
  logged in as `djacu` without a prompt.
- `view-yubikey-guide` from the launcher opens the README in a window; the
  diceware launcher opens Firefox on the page; Firefox shows no first-run
  tab and no network error dialogue that blocks use.
- Desktop sanity, not ceremony coverage: `gpg --quick-gen-key` with a
  passphrase and no `--batch` pops pinentry-qt, not curses. The ceremony
  itself uses loopback pinentry and never shows a prompt.

Hardware, on the ceremony laptop:

- The same boot checks, plus `gpg --card-status` recognising the YubiKey
  once, to prove the ccid path works on that machine even though the
  ceremony does not need it.

Acceptance is the signed commit in the last step of the ilmenite leg,
verified by GitHub, dated before 2026-10-19.

### 8. Commits

Attr-path subjects as in `docs/plans/completed/ilmenite-laptop-bringup.md`,
each with the `Assisted-by: Claude Code (claude-fable-5-1)` trailer, in this
order so every intermediate state passes `nix flake check`:

1. `docs/plans: add uraninite yubikey live iso` (this file)
1. `theonecfg: add uraninite to knownHosts as type live`
1. `hydraJobs: skip live hosts in systemConfigs`
1. `hydra-jobs: add common.nix after keywright`
1. `packages: add drduh-yubikey-guide and diceware-page`
1. `nixosModules.profiles.yubikey-live: init`
1. `nixosConfigurations.uraninite: init`
1. `hydra-jobs: add images.nix for live hosts`
1. `overlays: add theonecfgModulesPath`
1. `overlays: add the nixosTests overlay with the yubikey-live VM test`
1. `hydra-jobs: add vm-tests.nix`
1. `docs/reference/ores.md: assign uraninite to the live ISO`
1. `docs/runbooks: add renew-yubikey-gpg-subkeys`
1. after the ceremony: `homeModules.users.djacu.programs.gpg: renew subkeys to 2027-10-19`
1. `docs/plans: complete uraninite yubikey live iso`

## Risks and open assumptions

- The backup sticks hold one LUKS partition each (stated by the owner, not
  yet seen by the runbook). Inside, a dated `GNUPGHOME` directory as the
  guide creates is assumed. If the layout inside differs, only the copy
  line of the runbook changes.
- The backup files' ownership is unknown; the runbook copies as root and
  chowns, which works regardless.
- The certify passphrase is assumed known. Without it nothing here helps and
  the fallback is a new certify key, which is a different plan.
- `require-secmem` in drduh's `gpg.conf` makes gpg refuse to run if `mlock`
  fails. Default limits on this ISO are the same as on ilmenite where it
  works; if it bites, the gotcha is `ulimit -l unlimited` in the ceremony
  shell.
- Plasma on a live ISO with `all-hardware.nix` is roughly 3 to 4 GB. If
  Hydra's disk or build time becomes a problem, the `live` type can be
  filtered out of `hydraJobs` without touching anything else. A local run of
  `verify-hydra-system-configs` now also builds the ISO.
- `programs.firefox` on an air-gapped host: Firefox will try and fail to
  reach the network at startup; expected to be harmless. Checked in the
  manual QEMU boot.
- `environment.etc."gnupg/gpg.conf"` applies to root too, which is wanted.
- GitHub documents that commits keep their Verified status from the record
  made at first verification, so removing and re-adding the key is safe; the
  exact UI wording may differ from the runbook, which describes intent.

## Exit criteria

- Every targeted build in section 7 passes, including the `yubikey-live`
  VM test.
- `uraninite` evaluates, builds, and the real ISO boots in QEMU with every
  manual check above green.
- The scripted rehearsal in the VM test passes and runs the same renewal
  line as the runbook.
- The real ceremony produces a public key whose three subkeys expire
  2027-10-19 and whose certify key still never expires, imported on all five
  daily machines, committed to this repo, and uploaded to GitHub.
- `git log -1 --show-signature` on a fresh commit says `Good signature`,
  GitHub shows Verified on it and on an older commit.
- The runbook exists and was followed, with corrections folded back in.
- This plan moved to `docs/plans/completed/` with the status line updated.

## Follow-ups outside this plan

- An automated boot test of the real ISO in the shape of
  `nixos/tests/boot.nix`: `nixosConfigurations.uraninite.extendModules` with
  `testing/test-instrumentation.nix`, its `isoImage` booted with `-cdrom`
  and OVMF and no `-netdev`. It would cover EFI boot, squashfs and autologin
  on the image, at the price of a second 3 to 4 GB ISO build per check.
- An aarch64 variant if a non-x86 laptop is ever the ceremony machine.
- Migrate `homeConfigs` and `systemConfigs` out of `hydra-jobs/default.nix`
  into release-lib jobset files over `hydra-jobs/common.nix`, and port
  keywright's `verify-hydra-jobset` so any jobfile can be built locally.
- A `live` entry for a general NixOS installer ISO reusing the same profile
  split, if wanted.
- Re-verify the pinned facts above whenever `nixpkgs-unstable` is bumped
  before the next renewal in October 2027.
