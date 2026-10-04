# Plan: ilmenite — Framework Laptop 13 Pro bringup

**Status:** Design approved 2026-10-03; plan under review
**Started:** 2026-10-03
**Owner:** djacu

## Summary

Add `ilmenite`, a Framework Laptop 13 Pro (Intel Core Ultra Series 3), as a
new NixOS host modelled on `malachite`: ZFS native encryption with a
passphrase prompt, root rollback to an empty snapshot on every boot,
impermanence bind mounts from a persist dataset, systemd-boot, Plasma via the
desktop profile, and the same `djacu` home profiles.

Three deliberate differences from malachite: the Series 3 nixos-hardware
module, a swap partition with per-boot random encryption and no resume
device, and `stateVersion = "26.05"` for both NixOS and home-manager.

Install runs from argentite with `nixos-anywhere` against the live ISO already
booted on the laptop. A standby power investigation follows the install as a
separate spike and writes its findings to
`docs/investigations/ilmenite-standby-power.md`.

Decisions taken during design (2026-10-03):

- Hibernation dropped. It was the original motivation but requires encrypted
  swap plus an initrd ordering guard, and the user chose not to pursue it.
- Swap kept at 32 GB with `randomEncryption = true` for memory pressure only.
- A fresh `djacu` password hash; root reuses malachite's hash (user decision
  2026-10-03). Set
  with `hashedPassword` rather than malachite's `initialHashedPassword`: with
  `users.mutableUsers = false` the module copies the latter into the former
  anyway, and `hashedPassword` states the intent (enforced on every
  activation, and `/etc/shadow` is rolled back each boot).
- The out-of-tree `framework_laptop` kernel module stays enabled (default from
  nixos-hardware) because it is the only path to a battery charge limit on
  this EC.

## Hardware inventory

Collected 2026-10-03 over SSH from the NixOS 26.05 minimal live ISO
(kernel 6.18.33) at 10.0.10.80.

| Component   | Finding                                                                                              |
| ----------- | ---------------------------------------------------------------------------------------------------- |
| Board       | `FRANMJCP07` rev A7, SKU `FRANVZCP07`, DMI product "Laptop 13 Pro (Intel Core Ultra Series 3)"       |
| Firmware    | Insyde BIOS 03.02 (2026-05-26); EC `sakura-3.0.2`; Secure Boot disabled; TPM 2.0 present             |
| CPU         | Intel Core Ultra X7 358H, 16 cores, 16 threads                                                       |
| Memory      | 64 GB LPCAMM2 (62 GiB usable)                                                                        |
| Disk        | WD_BLACK SN850X 2 TB, `nvme-WD_BLACK_SN850X_2000GB_25356W800320`, blank, 512 B LBA (4 KiB available) |
| GPU         | Panther Lake Arc B390 `8086:b082`, bound by `xe`; DMC, GuC and HuC firmware loaded                   |
| NPU         | `8086:b03e`, `intel_vpu` firmware loaded                                                             |
| Wi-Fi / BT  | Intel Wi-Fi 7 BE211 (CNVi, `iwlmld`), firmware `sc-a0-wh-b0-101`; Intel Bluetooth over PCIe          |
| Fingerprint | Goodix `27c6:609c`                                                                                   |
| Audio       | Realtek ALC285 on HDA at `00:1f.3`; speaker `0x17`, headphone `0x21`, mics `0x12`/`0x19`             |
| Input       | PixArt touchpad `PIXA3854`, touch panel `CSW1322` (`3558:14fd`), both i2c-hid; PS/2 keyboard         |
| Display     | eDP 2880x1920                                                                                        |
| Sleep       | `mem_sleep` offers only `s2idle`; ACPI reports S0, S4, S5 (no S3)                                    |
| Battery     | `BAT1` 4640 mAh design at 15.64 V (about 72.6 Wh), reports `charge_*` not `energy_*`                 |
| USB4        | Two Thunderbolt domains                                                                              |
| EC drivers  | In-tree `cros_ec_lpcs` loaded; hwmon fan + 5 temps, keyboard backlight LED, charging/power LEDs      |

Notes from the inventory:

- `cros-charge-control` logged "Framework charge control detected, preventing
  load". Kernel commit `3664706e87` (2024-06-30) explains: Framework's EC has a
  custom charge-limit command that overrides the standard one, so the in-tree
  driver refuses to load unless forced with a module parameter. Hence the
  out-of-tree module stays on.
- The kernel applies `ALC295_FIXUP_FRAMEWORK_LAPTOP_LIMIT_INT_MIC_BOOST` for
  subsystem `f111:000f` ("Framework Laptop 13 Pro PTL"). It fixes headset mic
  detection and caps internal mic boost. No speaker tuning in-kernel.
- `nixos-generate-config --no-filesystems` on the live ISO produced the same
  module list as malachite's `hardware.nix` plus
  `hardware.cpu.intel.npu.enable = true;`.
- EFI variables hold two stale "Windows Boot Manager" entries pointing at a
  GPT partition that no longer exists. Harmless; optional cleanup after
  install.
- `dmesg` warnings are benign firmware noise: ACPI `_CPC` package type
  mismatches on every core, `ucsi_acpi` alt-mode registration failures on the
  port holding the USB-C hub, `igen6_edac` BAR overlap.

Raw outputs were kept in the session scratchpad only; the table above is the
record.

## Verified facts the design depends on

Each item was checked against source at the flake's current pins, not
assumed.

- `nixos-hardware` pin has `framework-intel-core-ultra-series3`, byte-identical
  to upstream as of 2026-10-03. It requires kernel >= 6.17 (repo pins
  `linuxPackages_6_18`), enables `services.fwupd`, and imports the 13-inch
  common module (fprintd, framework-tool, EC kmod, iio sensors, expansion-card
  udev rule) plus `common/intel.nix` (`nvme.noacpi=1`, acpilight, blacklists
  `cros-usbpd-charger`, headphone-noise udev rule).
- `common/intel.nix` pulls `common/gpu/intel`, whose `hardware.intelgpu.driver`
  defaults to `i915` and loads it in the initrd, and whose `vaapiDriver = null`
  installs both the legacy and the media VAAPI drivers. The Lunar Lake module
  overrides both to `xe` and `intel-media-driver`; Panther Lake needs the same
  override and the Series 3 module does not set it.
- `hardware.framework.enableKmod` defaults to true for kernel >= 6.10 and builds
  `linuxPackages_6_18.framework-laptop-kmod` (`0-unstable-2024-09-15`, upstream
  HEAD), loading `cros_ec` and `cros_ec_lpcs`. malachite evaluates with it on.
- The pinned `libfprint` 1.94.100 lists `usb:v27C6p609C*` under the `goodixmoc`
  driver. `security.pam.services.*.fprintAuth` defaults to
  `services.fprintd.enable`, so fingerprint auth is wired when fprintd is on.
- `hardware.cpu.intel.npu.enable` exists at the pin (`hardware/cpu/intel-npu.nix`).
  It adds `intel-npu-driver` (MIT), `level-zero`, and the NPU firmware. No
  unfree packages.
- The nixpkgs ZFS module appends `nohibernate` unless
  `boot.zfs.unsafeAllowHibernation` is set. With hibernation dropped this is
  the wanted state. `boot.resumeDevice` stays empty because the disko swap
  entry omits `resumeDevice`.
- `boot.loader.systemd-boot.editor` defaults to `true` at this pin and
  malachite evaluates to `true`, so the `zfs_force=1` recovery edit is
  available from the boot menu. The repo's revert commits assumed it was
  off.
- OpenZFS (`cmd/zpool/zpool_main.c`, `zfs_force_import_required`) requires
  `-f` only when the pool was not exported and its recorded hostid differs
  from the running system's, or when multihost is active. A crash on the
  same host with a stable `networking.hostId` does not trigger it. The
  design keeps `forceImportRoot = true` for parity with the other hosts; see
  `scheelite-force-import-root-decision.md` for the open fleet decision.
- `nixos-anywhere` 1.13.0 is in the flake's `legacyPackages` and wraps
  `sshpass`, so `--env-password` works with the live ISO's root password.
  The ISO's `/etc/os-release` has `VARIANT_ID=installer`, which makes
  nixos-anywhere skip kexec. `--disk-encryption-keys` files are written to the
  installer before the disko script runs; `--extra-files` is untarred into
  `/mnt` after disko mounts and before `nixos-install`; the reboot phase
  exports ZFS pools, which avoids the hostid import refusal on first boot.
- disko passes `rootFsOptions` verbatim to `zpool create` and has no handling
  for `keylocation=prompt`, so a remote, non-interactive install must supply
  the key from a file. disko's own `example/zfs.nix` uses
  `keylocation = "file:///tmp/secret.key"` and a post-create hook to switch to
  `prompt`. `postCreateHook` is available on every disko type including
  zpools.
- OpenZFS (`lib/libzfs/libzfs_crypto.c`, `get_key_material_stream`) reads a
  passphrase from a file with `getline` and trims the trailing newline, so a
  file written with `printf '%s\n'` matches the same passphrase typed at the
  initrd prompt later.
- `boot.zfs.requestEncryptionCredentials` defaults to `true`; the initrd import
  service prompts with `systemd-ask-password` for datasets whose
  `keylocation` is `prompt`.
- NixOS `swapDevices.*.randomEncryption.enable` creates
  `/dev/mapper/<device-name>` with a fresh key each boot via a generated
  `mkswap-*` unit. disko's swap type maps `randomEncryption = true` onto it.
- Panther Lake's PMC driver (`drivers/platform/x86/intel/pmc/ptl.c`) is in
  the live kernel and exposes `substate_residencies`, `slp_s0_residency_usec`,
  and `s0ix_blocker` under `/sys/kernel/debug/pmc_core/`. These are the
  measurement inputs for the standby spike.
- Plasma 6 powerdevil stores sleep behaviour in `powerdevilrc` under
  `[AC]`, `[Battery]`, `[LowBattery]` groups, `SuspendAndShutdown` subgroup,
  keys `LidAction` and `SleepMode` (1 = suspend, 2 = hybrid, 3 =
  suspend-then-hibernate). Recorded for the spike's follow-up; not used in
  this plan.
- Known firmware issue: FrameworkComputer/SoftwareFirmwareIssueTracker#274
  (opened 2026-09-30, open, no vendor response as of 2026-10-01) and a
  community thread report the 13 Pro on BIOS 3.02 hard-resetting instead of
  resuming from s2idle, with a fatal BERT record. The spike must look for
  this.

## Non-goals

- No hibernation, no resume device, no `unsafeAllowHibernation`.
- No sops secrets file for ilmenite yet. The host SSH key is seeded so one can
  be added later without an identity change.
- No Secure Boot or lanzaboote. Secure Boot stays off in firmware.
- No standby configuration before the spike has numbers.
- No speaker EQ. nixos-hardware's `audioEnhancement` chain is tuned for the
  classic 13 chassis and its own description says the Pro needs different
  tuning.
- No 4 KiB LBA reformat of the NVMe. It would be free now on a blank disk,
  but it adds a variable while the firmware resume question is open. Revisit
  only with a reinstall.
- No ZFS ARC cap. Default is half of RAM (32 GiB), same as malachite.
- No changes to malachite, cassiterite, argentite, or scheelite. The only
  shared file touched is `theonecfg/default.nix`, and a gate below proves the
  other hosts' derivations are unchanged.

## Phases

### Phase 0: prerequisites

What: a feature branch, fresh password hashes, and the files tracked so the
flake can see them.

- Branch `djacu/ilmenite-bringup` from `main`. All commits in this plan land
  there and go up as one PR.
- Generate two SHA-512 hashes on argentite and keep them for Phase 2:
  ```fish
  nix shell .#mkpasswd -c mkpasswd -m sha-512
  ```
  Run once for root and once for `djacu`. Hashes are safe to commit; the
  existing hosts commit theirs.
- After creating new files, run `git add -N` on them. Flakes ignore untracked
  files, and the symptom is a misleading "option does not exist" or
  "attribute missing" error.

Why first: the hashes and tracking are inputs to every later evaluation.

### Phase 1: register the host

What: make the fleet aware of ilmenite and expose the hardware module.

File `theonecfg/default.nix`:

- Add to `knownHosts`, keeping alphabetical order:
  ```nix
  ilmenite = {
    type = "laptop";
    forwardAgent = true;
  };
  ```
  The host assertion in `nixos-configurations/default.nix` rejects any
  hostname not in this set, so this must exist before Phase 2 evaluates.
- Add `framework-intel-core-ultra-series3` to the `nixosHardware` inherit
  list.

File `docs/reference/ores.md`: fill the titanium row:

```
| titanium   | ilmenite     | laptop      | Framework 13 Pro (Core Ultra Series 3) | —     |
```

`nix fmt` realigns the table.

Why: both are tiny, mechanical, and unblock everything else.

### Phase 2: NixOS configuration

What: `nixos-configurations/ilmenite/` with four files cloned from malachite
and edited as listed. The directory name is the hostname; the auto-import in
`nixos-configurations/default.nix` needs no wiring.

`default.nix` (from malachite's):

- `theonecfg.nixosHardware.framework-intel-core-ultra-series3` replaces the
  11th-gen import.
- `system.stateVersion = "26.05";`
- Add, with a comment pointing at the nixos-hardware gap:
  ```nix
  # Panther Lake is xe-only; nixos-hardware's shared Intel GPU module still
  # defaults to i915 in the initrd and installs both VAAPI drivers.
  hardware.intelgpu.driver = "xe";
  hardware.intelgpu.vaapiDriver = "intel-media-driver";
  ```
- Replace both `initialHashedPassword` lines with `hashedPassword` set to the
  Phase 0 hashes. Same effect on an immutable-users host; clearer name.
- Keep verbatim: `boot.kernelPackages = pkgs.linuxPackages_6_18`, systemd-boot
  with `canTouchEfiVariables`, `boot.supportedFilesystems = [ "zfs" ]`,
  `boot.zfs.devNodes = "/dev/disk/by-id"`, `boot.zfs.forceImportRoot = true`,
  the `rollback-root` initrd service, `hardware.bluetooth.enable`, the
  hostname-hash `networking.hostId`, the sudo lecture override,
  `services.zfs.autoScrub.enable`, timezone, `users.mutableUsers = false`,
  the common and desktop profiles, and `theonecfg.users.djacu.enable`.
- Add a one-line comment above `forceImportRoot` noting it is kept for fleet
  parity and that recovery is `zfs_force=1` from the systemd-boot editor.

`disko.nix` (from malachite's):

- `device = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_25356W800320";`
- Swap partition: keep `size = "32G"` and `type = "8200"`; content becomes
  ```nix
  content = {
    type = "swap";
    randomEncryption = true;
  };
  ```
  No `resumeDevice`.
- Pool `rootFsOptions`: keep every option as malachite has it, but
  `keylocation = "file:///tmp/secret.key";` instead of `"prompt"`, with a
  comment that this path exists only on the installer during
  `nixos-anywhere` and is switched to `prompt` by the hook below.
- Add on the `zroot` zpool:
  ```nix
  postCreateHook = ''
    zfs set keylocation=prompt zroot
  '';
  ```
- Datasets unchanged: `local`, `safe`, `local/root` with the `@empty`
  snapshot hook, `local/nix`, `safe/home`, `safe/persist`.

`hardware.nix`: the live ISO's `nixos-generate-config --no-filesystems`
output, formatted like malachite's. Module list `xhci_pci thunderbolt nvme uas sd_mod`, `kvm-intel`, `hardware.cpu.intel.npu.enable = true`, the
`updateMicrocode` default. Keep the generated-file header comment; the other
hosts do.

`impermanence.nix`: byte-for-byte copy of malachite's. The persisted list
already covers fprint, fwupd, bluetooth, NetworkManager, power-profiles-daemon,
sddm, and the SSH host keys and machine-id as files.

Why this shape: it is the pattern the other three ZFS hosts use, including the
rollback service the runbook in `docs/runbooks/` documents, so operational
knowledge transfers.

### Phase 3: home-manager configuration

What: `home-configurations/ilmenite/djacu/default.nix`, a copy of
malachite's. `home.stateVersion = "26.05"` already; same common, desktop,
and developer profiles. Exposed as `homeConfigurations.ilmenite-djacu` by the
auto-import.

### Phase 4: pre-install verification gates

What: prove the configuration before the laptop is touched. All from
argentite, on the branch, with the files tracked.

Build both artefacts:

```fish
nix build .#nixosConfigurations.ilmenite.config.system.build.toplevel
nix build .#homeConfigurations.ilmenite-djacu.activationPackage
```

The first build also proves `framework-laptop-kmod` compiles against
6.18.49 and that the ZFS module version matches the kernel.

Evaluate the load-bearing values and compare with the expectations:

| Check                                            | Expect                                                                                                                                                               |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config.boot.resumeDevice`                       | empty string                                                                                                                                                         |
| `config.boot.kernelParams`                       | contains `nohibernate` and `nvme.noacpi=1`; contains no `resume=`                                                                                                    |
| `config.swapDevices`                             | one entry, device `/dev/disk/by-partlabel/disk-disk1-swap`, `randomEncryption.enable = true`, `realDevice = /dev/mapper/dev-disk-byx2dpartlabel-diskx2ddisk1x2dswap` |
| `config.boot.initrd.kernelModules`               | contains `xe`, not `i915`                                                                                                                                            |
| `config.hardware.intelgpu`                       | `driver = "xe"`, `vaapiDriver = "intel-media-driver"`                                                                                                                |
| `config.hardware.framework.enableKmod`           | `true`                                                                                                                                                               |
| `config.services.fprintd.enable`                 | `true`                                                                                                                                                               |
| `config.services.fwupd.enable`                   | `true`                                                                                                                                                               |
| `config.hardware.cpu.intel.npu.enable`           | `true`                                                                                                                                                               |
| `config.disko.devices.zpool.zroot.rootFsOptions` | `encryption = aes-256-gcm`, `keyformat = passphrase`, `keylocation = file:///tmp/secret.key`                                                                         |
| `config.fileSystems` (device, fsType, options)   | `/` on `zroot/local/root`, `/nix` on `zroot/local/nix`, `/home` on `zroot/safe/home`, `/persist` on `zroot/safe/persist`, all `zfs` with `zfsutil`; `/boot` vfat     |
| `config.networking.hostId`                       | 8 hex chars, equals `substring 0 8 (sha256 "ilmenite")`                                                                                                              |
| `config.boot.loader.systemd-boot.editor`         | `true`                                                                                                                                                               |

Fleet-safety gate: record
`nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
for malachite, cassiterite, argentite, and scheelite on `main` and again on
the branch. All four must be identical, proving the `theonecfg/default.nix`
edit changed nothing for existing hosts.

Formatting gate: `nix fmt` then `git diff --exit-code` shows no changes.

Why before install: every one of these is cheap, and a wrong swap or
keylocation value would only surface after the disk is formatted.

### Phase 5: install runbook

What: `docs/runbooks/install-laptop-with-nixos-anywhere.md`, the procedure
for a ZFS-encrypted, impermanence laptop installed remotely. The README
covers scheelite's scripted multi-disk install only. All commands are
fish-compatible and run on argentite in the repo root unless marked.

Prerequisites on the laptop: boot the NixOS 26.05 minimal stick with Secure
Boot off, wired network via the USB-C hub, set a throwaway root password
with `passwd`, note the address from `ip -4 -brief addr`.

Steps:

1. Confirm the target disk id still matches `disko.nix`:
   ```fish
   ssh root@10.0.10.80 'ls -l /dev/disk/by-id/ | grep nvme-WD'
   ```
1. Stage the ZFS passphrase and the identity files in a temp dir:
   ```fish
   set work (mktemp -d)
   read -s -P 'ZFS passphrase: ' zfspass
   printf '%s\n' $zfspass > $work/zfs.key
   set -e zfspass
   install -d -m 0755 $work/extra/persist/etc/ssh
   ssh-keygen -q -t ed25519 -N '' -C ilmenite -f $work/extra/persist/etc/ssh/ssh_host_ed25519_key
   ssh-keygen -q -t rsa -b 4096 -N '' -C ilmenite -f $work/extra/persist/etc/ssh/ssh_host_rsa_key
   systemd-id128 new > $work/extra/persist/etc/machine-id
   chmod 0444 $work/extra/persist/etc/machine-id
   ```
   The newline in the key file is trimmed by ZFS. The keys land in the
   persist dataset because `/etc` on the root dataset is rolled back on every
   boot; `--copy-host-keys` would put them in the wrong place.
1. Install:
   ```fish
   set -x SSHPASS password
   nix run .#nixos-anywhere -- \
     --env-password \
     --flake .#ilmenite \
     --target-host root@10.0.10.80 \
     --disk-encryption-keys /tmp/secret.key $work/zfs.key \
     --extra-files $work/extra
   set -e SSHPASS
   rm -rf $work
   ```
   nixos-anywhere detects the installer, runs disko (destroy, format, mount),
   copies the closure built on argentite, runs `nixos-install`, exports the
   pool, and reboots. Watch for the disko phase printing the zpool create and
   the hook's `zfs set keylocation=prompt`.
1. First boot on the laptop: the initrd asks "Enter key for zroot". Log in to
   Plasma as `djacu` with the new password.
1. Apply home-manager on the laptop (needs the repo cloned there or reachable):
   ```fish
   nix run --inputs-from . home-manager-unstable -- switch --flake .#ilmenite-djacu
   ```
1. Post-install checks on the laptop, each with its expected result:
   - `hostid` equals `networking.hostId`.
   - `zpool status zroot` ONLINE; `zfs get -H keylocation zroot` is `prompt`.
   - `swapon --show` lists `/dev/mapper/dev-disk-byx2dpartlabel-diskx2ddisk1x2dswap` (the name Phase 4 reads from `swapDevices.*.realDevice`); `cat /proc/cmdline` has `nohibernate` and no `resume=`.
   - `lsmod | grep -E '^(xe|framework_laptop|cros_ec_lpcs) '` lists all three.
   - `cat /sys/class/power_supply/BAT1/charge_control_end_threshold` exists.
   - `fprintd-enroll` succeeds, then `sudo -k; sudo true` accepts a finger.
   - `fwupdmgr get-devices` lists the system firmware and the fingerprint reader.
   - Speakers, headset jack, Wi-Fi, and Bluetooth each work once.
   - `systemctl --failed` is empty; `journalctl -b -p warning` has nothing beyond the firmware noise listed in the inventory.
   - `ls -la /persist/etc/ssh /persist/etc/machine-id` shows the seeded files, and `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` matches the staged key's fingerprint.
1. Optional cleanup: `sudo efibootmgr` and delete the stale Windows entries
   with `sudo efibootmgr -b <id> -B` after confirming each points at the
   nonexistent GPT partuuid `2155ccf0-ab99-4e0f-878e-bd5fda3afe0c`.

Rollback: the disk was blank, so a failed install loses nothing. Fix the
config, re-run step 3. If the first boot cannot import the pool, boot the
stick and `zpool import -f zroot; zpool export zroot`, then reboot.

### Phase 6: commits

Each commit carries `Assisted-by: Claude Code (claude-fable-5-1)`. Subjects
follow the repo's attr-path style. Order matches dependency order.

1. `docs/plans/active: add ilmenite laptop bringup plan` (this document)
1. `theonecfg: add ilmenite to knownHosts and nixosHardware`
1. `nixosConfigurations.ilmenite: init`
1. `homeConfigurations.ilmenite.djacu: init`
1. `docs/reference/ores.md: assign ilmenite to the Framework Laptop 13 Pro`
1. `docs/runbooks: add install-laptop-with-nixos-anywhere`

Commit 3's body records the hardware (board, BIOS, disk id) and the three
differences from malachite with their reasons. The plan moves to
`docs/plans/completed/` in a closing commit once Phase 7 is written up.

### Phase 7: standby power spike

What: measure what the laptop actually does when the lid closes on battery,
then decide. Output is `docs/investigations/ilmenite-standby-power.md` with
numbers and a recommendation. Any configuration change that results is a
separate bounded task.

Procedure, run on ilmenite after Phase 5, Plasma defaults untouched:

1. Record BIOS version, `cat /sys/power/mem_sleep`, and
   `journalctl --list-boots` as the baseline.
1. For each scenario, on battery, lid closed for a timed 30 minutes:
   - before: `date +%s`, `cat /sys/class/power_supply/BAT1/charge_now`,
     `voltage_now`, `cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec`,
     and `substate_residencies` (needs `sudo`).
   - after resume: the same, plus `journalctl -b -k | grep -E 'PM: suspend (entry|exit)'`
     and `cat /sys/kernel/debug/pmc_core/s0ix_blocker`.
   - compute: drain in %/h and Wh/h (charge delta in mAh times average
     voltage), and S0ix residency as a fraction of wall time.
1. Scenarios, one variable at a time: (a) nothing plugged in; (b) with the
   expansion cards installed; (c) with the USB-C hub and Ethernet attached.
1. After every resume, `journalctl -b -k | grep -i BERT` and
   `journalctl --list-boots` to detect the firmware reset described in
   issue #274.
1. `sudo powertop --html=powertop.html` once on battery, idle, lid open, for
   a tunables baseline. Do not apply `--auto-tune`.

Decision rules:

- Residency above 90% and drain under about 1%/h: s2idle is healthy. Keep
  Plasma's lid-to-sleep default. Done.
- Residency low or drain high: use `s0ix_blocker` and powertop to find the
  offender. Typical suspects are expansion cards and USB autosuspend. Each
  fix is its own task with a before/after measurement.
- Any failed resume with a BERT record: set Plasma's lid action to lock plus
  screen off until a firmware fix ships, and record the BIOS version and
  journal excerpts in the investigation doc. Subscribe to issue #274.

Since hibernation is out of scope, there is no suspend-then-hibernate
fallback. Long unattended periods mean shutting down; the spike's numbers say
how long "long" is.

## Risks and open assumptions

- Firmware resume resets on BIOS 3.02 are reported by two users. If they
  reproduce here, lid-close sleep is unsafe until Framework ships a fix. The
  spike detects this; nothing in the install depends on it.
- `framework-laptop-kmod` must build against 6.18.49. Phase 4's toplevel
  build proves it. If it fails, the fallback is
  `hardware.framework.enableKmod = false` and setting the charge limit in
  BIOS setup.
- Fingerprint support is inferred from the libfprint device table, not
  exercised. Enrollment in Phase 5 is the real test.
- The `xe` initrd choice is inferred from the live kernel binding `xe`
  without any `force_probe`. If the initrd console regresses, the fallback is
  `hardware.intelgpu.loadInInitrd = false`.
- `--extra-files` ownership: files are extracted root-owned with their
  staged modes. Private keys are created `0600` by ssh-keygen. If sshd
  rejects a key on first boot, the fix is a `chmod` on `/persist/etc/ssh`.
- The live ISO's root password is sent over the LAN in the clear by
  `sshpass`. It is a throwaway on an ephemeral system; acceptable.

## Exit criteria

- All Phase 4 gates pass and the four existing hosts' derivation paths are
  unchanged.
- ilmenite boots from its own disk, prompts for the ZFS passphrase, reaches
  Plasma, and every Phase 5 post-install check holds.
- home-manager applied; shell, editor, and desktop profiles present.
- `docs/investigations/ilmenite-standby-power.md` exists with measurements
  for the three scenarios and a recommendation.
- This plan and the runbook moved to their final locations in a closing
  commit.

## Follow-ups outside this plan

- Upstream the `xe` and `intel-media-driver` defaults into nixos-hardware's
  `intel-core-ultra-series3` module.
- Speaker tuning for the Pro chassis, once a community filter chain exists.
- `secrets/ilmenite.yaml` and a `.sops.yaml` recipient derived from the seeded
  host key, when the host needs secrets.
- Align the other hosts from `initialHashedPassword` to `hashedPassword` in
  a separate PR. No behaviour change, but it alters each host's derivation,
  so it stays out of this branch's fleet-safety gate.
- Battery charge limit via Plasma's battery settings, which reads
  `charge_control_end_threshold`.
