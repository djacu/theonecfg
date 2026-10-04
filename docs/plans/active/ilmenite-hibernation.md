# Plan: ilmenite — suspend-then-hibernate

**Status:** Design approved in conversation 2026-10-04; this document awaits review, then an implementation plan follows
**Started:** 2026-10-04
**Owner:** djacu
**Gate:** `docs/investigations/ilmenite-hibernate-firmware-test.md` (passed, 3 of 3 cycles)

## Summary

Give `ilmenite` (Framework Laptop 13 Pro, Intel Core Ultra Series 3, 64 GB)
MacBook-style lid behaviour: close the lid and the machine suspends (s2idle,
measured 0.43 W); after three hours on battery, or at the low-battery alarm,
it wakes itself, writes a hibernation image, and powers off; open the lid, type
the disk passphrase once, and the session is back. On AC it just stays
suspended.

Hibernation needs a resume image on swap with a persistent key, so the random
per-boot swap key goes. To keep a single passphrase on cold boot and on
resume, and to get a swap large enough that hibernation is never refused, the
disk is re-laid out: two LUKS2 containers with one passphrase, 68 GB swap in
one and the ZFS pool in the other, the pool itself no longer natively
encrypted. That is a reinstall with the existing runbook. The initrd gets one
ordering line so the pool import can never race the resume, which is the
reason upstream labels ZFS hibernation unsafe, and `boot.zfs.forceImportRoot`
flips to `false` on this host because the hibernation option asserts it.

## Decisions

| Decision                 | Choice                                                  | Why                                                                                                                                                                                       |
| ------------------------ | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scope                    | ilmenite only                                           | malachite and cassiterite keep their layouts; a shared module can come later if wanted                                                                                                    |
| Sleep mode               | suspend-then-hibernate                                  | s2idle is cheap and instant; hibernate only pays off after hours                                                                                                                          |
| Policy                   | hibernate after 3 h on battery, never on AC             | closest to macOS standby; docked laptop never writes an image                                                                                                                             |
| Passphrases              | one, shared by both LUKS containers, also on cold boot  | systemd-cryptsetup caches the first answer in the kernel keyring and the second container takes it from there                                                                             |
| Encryption layout        | LUKS swap + LUKS-wrapped pool, no ZFS native encryption | standard pattern, no custom glue; raw encrypted sends and per-dataset keys given up; pool metadata now hidden inside LUKS; TPM2/FIDO2 unlock becomes possible later                       |
| Swap size                | 68 GB                                                   | systemd hibernates only if `Active(anon)` fits in 98 % of free swap; 68 GB covers all of the 64 GB RAM with margin; 3.4 % of the 2 TB disk                                                |
| How to change the layout | reinstall, fresh start                                  | ZFS vdevs cannot shrink, so the swap cannot grow in place; the install is days old and nothing on it is worth migrating; fresh host keys and machine-id as the runbook already generates  |
| Firmware risk            | tested first on the installer stick                     | a community report on this board and BIOS 03.02 described hibernate resume failing with `_WAK.G4` ACPI errors; it did not reproduce here in three cycles, one on battery without the dock |

## Verified facts the design depends on

Checked at the flake pin (nixpkgs-unstable 26.11.20260905.c043004, store path
`/nix/store/igrbwnqkyn9z88d3kvwhgfrwh6firl0w-source`; disko
`/nix/store/w2c23ykc12mswlg8hrrjzb5gv9gvkzwq-source`; systemd 261.2;
powerdevil 6.7.4; kernel 6.18). Re-verify after a pin bump.

- `nixos/modules/tasks/filesystems/zfs.nix`: `nohibernate` is appended to the
  kernel command line unless `boot.zfs.unsafeAllowHibernation` is set (line
  718); that option asserts `!forceImportRoot && !forceImportAll` with the
  message "will cause data corruption" (line 682).
- OpenZFS `cmd/zpool/zpool_main.c`, `zfs_force_import_required`: `-f` is only
  required when the pool was not exported and its recorded hostid differs from
  the running one, or when multihost is active. ilmenite's hostid is a fixed
  hash of its hostname and `boot.initrd.systemd.contents."/etc/hostid"` is set
  from it, so a crash on the same machine imports without `-f`.
  `boot.loader.systemd-boot.editor` is `true` at the pin, so `zfs_force=1`
  can be typed at the boot menu if ever needed.
- The initrd race: `zfs-import-zroot.service` (zfs.nix `createImportService`,
  line 152) is `DefaultDependencies=no`, after `systemd-modules-load.service`
  and `systemd-ask-password-console.service`, before the pool mounts and
  `zfs-import.target`. `systemd-hibernate-resume.service` (systemd 261 unit) is
  `DefaultDependencies=no`, `Before=local-fs-pre.target`, with
  `AssertPathExists=/etc/initrd-release`. Nothing orders one after the other.
  The generator (`src/hibernate-resume/hibernate-resume-generator.c`) enables
  the resume unit through `sysinit.target.wants` when `resume=` is on the
  command line or the `HibernateLocation` EFI variable is set, and adds a
  drop-in with `BindsTo=` and `After=` the resume device unit.
  `nixos/modules/system/boot/systemd/initrd.nix` line 543 puts
  `resume=${boot.resumeDevice}` on the command line. `rollback-root` is
  already `after = [ "zfs-import-zroot.service" ]`.
- disko `lib/types/luks.nix`: `passwordFile` is fed to `cryptsetup` as
  `--key-file <(echo -n "$(cat file)")`, so a trailing newline is stripped;
  `initrdUnlock` defaults to `true` and adds `boot.initrd.luks.devices.<name>`
  merged with `settings`; the inner content sees `/dev/mapper/<name>` as its
  device. `lib/types/swap.nix`: `resumeDevice = true` sets `boot.resumeDevice`
  to the swap's device. `lib/types/zfs.nix` registers that device for
  `zpool create`.
- `nixos/modules/system/boot/luksroot.nix`, systemd stage 1: writes
  `/etc/crypttab` with `discard` for `allowDiscards` and
  `no-read-workqueue,no-write-workqueue` for `bypassWorkqueues` (line 590);
  forces `services.lvm.enable` and `boot.initrd.services.lvm.enable` so the
  device-mapper udev rules are in the initrd (line 1238), which is what makes
  `/dev/disk/by-id/dm-name-*` exist there for `boot.zfs.devNodes`. systemd's
  cryptsetup generator sets `JobTimeoutSec=infinity` on the mapped device, so
  typing the passphrase slowly cannot time out the boot.
- One prompt for two containers: crypttab(5) at the pin says `password-cache=`
  defaults to `yes` and caches an interactively entered passphrase in the
  kernel keyring for 2.5 minutes; `src/shared/ask-password-api.c`
  (`ask_password_agent` and `ask_password_tty`) re-checks the keyring on an
  inotify event while a request is pending, so the second container's pending
  prompt is satisfied by the first answer.
- systemd `src/shared/hibernate-util.c`: hibernation is allowed only if
  `Active(anon)` from `/proc/meminfo` is at most `0.98 × (swap size − used)`;
  `/sys/power/image_size` is not consulted. `src/sleep/sleep.c`: when the
  hibernate step of suspend-then-hibernate fails it logs "Couldn't hibernate,
  will try to suspend again" and suspends with the hook argument
  `suspend-after-failed-hibernate`.
- systemd-sleep.conf(5) at the pin: with a battery, the low-battery alarm
  (ACPI `_BTP`, 5 %) is tried first; `HibernateDelaySec=` adds a timer and the
  earlier of the two wins; without `_BTP` the system wakes periodically to
  estimate drain; `HibernateOnACPower=no` starts the countdown only after AC
  is disconnected. Without a battery the delay defaults to 2 h.
- `nixos/modules/system/boot/systemd.nix`: `systemd.sleep.settings.Sleep`
  renders `/etc/systemd/sleep.conf`. `systemd/logind.nix`:
  `services.logind.settings.Login.HandleLidSwitch` (the old `lidSwitch` names
  are renamed aliases).
- Kernel 6.18 `kernel/power/hibernate.c`: `hibernation_available()` is false
  under `nohibernate` or lockdown; `resume_store` accepts a device path or
  `major:minor` and calls `software_resume()`. `kernel/power/swap.c`: with no
  resume device configured the image goes to the first active swap;
  `swsusp_check` restores the original swap signature as soon as it reads the
  image header.
- powerdevil 6.7.4 `PowerDevilProfileSettings.kcfg`: file `powerdevilrc`,
  group `[<ProfileId>][SuspendAndShutdown]` with `LidAction` (default
  `Sleep` when suspend is possible) and `SleepMode` (`1` SuspendToRam, `2`
  HybridSuspend, `3` SuspendThenHibernate; default `1`), and
  `InhibitLidActionWhenExternalMonitorPresent` default `true`. Profiles are
  `AC`, `Battery`, `LowBattery`. `daemon/powerdevilpowermanagement.cpp` only
  calls `SuspendThenHibernate` when logind reports `CanSuspendThenHibernate`.
  `nixos/modules/programs/environment.nix` line 34 puts `/etc/xdg` first in
  `XDG_CONFIG_DIRS`, so `/etc/xdg/powerdevilrc` is a system default that the
  user's own file overrides.
- Hardware: BIOS 03.02 enters S4 and resumes. Three cycles on the installer
  stick's 6.18.33, two on AC with the hub and one on battery without it: image
  written at about 3 GB/s, power off in about 5 s, resume with marker and
  uptime intact, battery device present, zero ACPI errors. Only restore-time
  error: `spd5118 0-0050` (DDR5 SPD sensor) returns `-6`, cosmetic. Measured
  s2idle: 0.43 W, 0.5 %/h, S0i2.2 (`ilmenite-standby-power.md`).

## Non-goals

- Hibernation on any other host. The policy stays host-specific until a
  second host wants it.
- TPM2 or FIDO2 unlock. The LUKS layout makes it possible later with
  `systemd-cryptenroll`; not part of this plan.
- Tuning the kernel image compressor or `image_size`. The defaults wrote the
  test image at 3 GB/s.
- Hybrid sleep, or hibernate-on-lid without a suspend phase.
- Migrating data from the current install. Fresh start.
- Changing the fleet `forceImportRoot` policy. ilmenite becomes the first
  data point for `docs/plans/active/scheelite-force-import-root-decision.md`.

## Design

### 1. Disk layout (`nixos-configurations/ilmenite/disko.nix`)

Same ESP. The swap and ZFS partitions become LUKS2 containers sharing one
passphrase.

```nix
swap = {
  size = "68G";
  content = {
    type = "luks";
    name = "cryptswap";
    # Install-time only: nixos-anywhere uploads the passphrase here with
    # --disk-encryption-keys. disko strips the trailing newline.
    passwordFile = "/tmp/secret.key";
    settings = {
      allowDiscards = true;
      bypassWorkqueues = true;
    };
    content = {
      type = "swap";
      resumeDevice = true;
    };
  };
};
zfs = {
  size = "100%";
  content = {
    type = "luks";
    name = "cryptzroot";
    passwordFile = "/tmp/secret.key";
    settings = {
      allowDiscards = true;
      bypassWorkqueues = true;
    };
    content = {
      type = "zfs";
      pool = "zroot";
    };
  };
};
```

The zpool block drops `encryption`, `keyformat`, `keylocation`, and the
post-create hook that switched the key location to `prompt`. Everything else
stays: `ashift`, `autotrim`, the five datasets with their mountpoints, and the
`zroot/local/root@empty` snapshot. `impermanence.nix` is unchanged. The
explicit `8200` partition type goes; the partition holds LUKS, not swap.

What follows from this without further configuration: both containers appear
in the initrd crypttab and unlock in stage 1 with one prompt;
`boot.resumeDevice` is `/dev/mapper/cryptswap` and the kernel command line
carries `resume=/dev/mapper/cryptswap`; the swap entry is plain swap on the
mapper with no `randomEncryption`.

`allowDiscards` passes TRIM through dm-crypt so the SSD and ZFS autotrim keep
working; the cost is that free-space patterns are visible on the raw disk.
`bypassWorkqueues` is the recommended dm-crypt setting for NVMe and is only
incompatible with authenticated encryption, which is not in use.

### 2. Boot and resume (`nixos-configurations/ilmenite/hibernation.nix`, new)

Imported from `default.nix` next to `disko.nix`, `hardware.nix`, and
`impermanence.nix`. The `boot.zfs.forceImportRoot = true` line and its comment
move out of `default.nix`.

```nix
boot.zfs.unsafeAllowHibernation = true;
boot.zfs.forceImportRoot = false;
boot.initrd.systemd.services.zfs-import-zroot.after = [
  "systemd-hibernate-resume.service"
  "systemd-cryptsetup@cryptzroot.service"
];
```

- `unsafeAllowHibernation` removes `nohibernate`. Its assertion requires no
  force import.
- `forceImportRoot = false` is safe on this host because the hostid is fixed
  and present in the initrd. Recovery from a refused import is `zfs_force=1`
  in the systemd-boot editor, which stays enabled on ilmenite.
- The `after` list closes the race. `resume=` is on the command line on every
  boot, so the resume unit always runs; it binds to the swap mapper, so it
  runs after the swap unlock. Cold boot: one prompt, both containers unlock,
  the resume unit finds no image and exits, the pool imports, root rolls back,
  mounts proceed. Resume boot: the chain stops at the resume unit and the
  kernel is replaced before anything touches the pool. The second entry makes
  the import wait for the pool container explicitly rather than through the
  import script's 60-second device retry loop.

Unchanged: `rollback-root` (already after the import), `networking.hostId`,
`boot.zfs.devNodes`, the kernel package, the image compressor.

Expected evaluated state, checked before anything is built:
`boot.kernelParams` without `nohibernate`; `boot.resumeDevice` equal to
`/dev/mapper/cryptswap`; `boot.initrd.luks.devices` with exactly `cryptswap`
and `cryptzroot`; the import unit's `after` containing both units;
`swapDevices` with one entry on the mapper and `randomEncryption.enable`
false.

### 3. Sleep policy (same file)

```nix
# What "sleep" means to systemd.
systemd.sleep.settings.Sleep = {
  HibernateDelaySec = "3h";
  HibernateOnACPower = false;
};

# Lid handling when no desktop session is running (SDDM screen).
services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";

# Lid handling inside Plasma, which takes over from logind while logged in.
# 3 = suspend-then-hibernate. A user choice in System Settings still wins
# over this system default.
environment.etc."xdg/powerdevilrc".text = ''
  [AC][SuspendAndShutdown]
  SleepMode=3

  [Battery][SuspendAndShutdown]
  SleepMode=3

  [LowBattery][SuspendAndShutdown]
  SleepMode=3
'';
```

Resulting behaviour with the lid closed:

- On battery: s2idle at 0.43 W. The 3-hour timer is armed, and the 5 %
  battery alarm too if the firmware exposes one. The earlier wakes the
  machine, writes the image, and powers off. Open the lid: passphrase, then
  the session. An overnight unplugged costs about 1.5 % plus one hibernate.
- On AC: s2idle indefinitely; the countdown starts only when AC is unplugged.
- With an external monitor attached: Plasma's default inhibit keeps the lid
  from doing anything, as today.

Plasma offers mode 3 only when logind reports suspend-then-hibernate as
possible, which includes the swap check at that moment; 68 GB always passes
on 64 GB of RAM. The lid action itself is already "sleep" by default; only
the mode changes.

### 4. Install and migration

Fresh start with `docs/runbooks/install-laptop-with-nixos-anywhere.md`, with
these changes:

1. Before wiping: on ilmenite, `git status` in the theonecfg clone confirms
   nothing unpushed lives only there. On argentite, remove the old host-key
   entries with `ssh-keygen -R` for the hostname and the addresses used.
1. Staging as today: a work directory with the passphrase file written with
   `printf '%s\n'`, fresh ed25519 and RSA host keys, and a fresh machine-id
   under `extra/persist/etc/`. The file name changes from `zfs.key` to
   `luks.key`; it still lands as `/tmp/secret.key` on the installer through
   `--disk-encryption-keys`.
1. The same `nixos-anywhere` invocation. disko formats both containers with
   the passphrase, opens them, makes the swap, creates the pool with no
   encryption properties, the datasets, and the `@empty` snapshot.
1. First boot: one prompt, pool imports, root rolls back, Plasma. Then the
   usual home-manager apply from a fresh clone, done by the owner.

Runbook edits: the ZFS key-location wording becomes "the disk passphrase",
with a note on what disko does with it for LUKS. Post-install checks gain
`swapon --show` expecting `/dev/mapper/cryptswap`, `/proc/cmdline` expecting
`resume=` and no `nohibernate`, and `zfs get encryption zroot` expecting
`off`.

### 5. Verification and acceptance

Before hardware, on argentite by evaluation and build: the expected state
from section 2; `/etc/systemd/sleep.conf` rendering `HibernateDelaySec=3h`
and `HibernateOnACPower=false`; `/etc/xdg/powerdevilrc` present with the
three groups; `services.logind.settings.Login.HandleLidSwitch` equal to
`suspend-then-hibernate`; a full build of ilmenite's `toplevel`; the other
hosts' `toplevel` derivation paths unchanged.

After the install, on the hardware. The owner drives; verification is
read-only over SSH.

1. Cold boot shows exactly one passphrase prompt. The initrd journal shows
   both cryptsetup units, then the resume unit, then the pool import, in that
   order.
1. `systemctl hibernate` from a Plasma session with a marker file in `/run`:
   power on, one prompt, session restored, marker present, no ACPI errors in
   dmesg; note whether `spd5118` still complains on the installed kernel.
1. `systemctl suspend-then-hibernate` with a temporary two-minute delay in a
   drop-in under `/run/systemd/sleep.conf.d/` (no rebuild): suspend, timed
   wake, hibernate, resume.
1. Lid closed on battery for ten minutes stays in s2idle. Lid closed
   overnight unplugged ends hibernated; `charge_now` before and after is
   recorded.
1. Lid closed on AC for over three hours stays suspended.
1. logind reports suspend-then-hibernate as possible (`busctl` on
   `CanSuspendThenHibernate`), the Plasma power page shows the mode, and
   whether `/sys/class/power_supply/BAT1/alarm` exists is recorded, since that
   decides whether systemd uses periodic estimation wakes.

Results go into `docs/investigations/ilmenite-hibernation-verification.md`.

## Risks and open assumptions

- If the battery exposes no alarm, systemd wakes periodically to estimate
  drain. That periodic wake is where the community report saw s2idle platform
  resets; the standby test did three wakes without one. Observe during
  verification; if it bites, the fallback is a plain `HibernateDelaySec`
  without estimation, which is a one-line change.
- Resume with the installed kernel, the `xe` driver under a running desktop,
  and systemd's own hibernate path were not exercised by the stick test.
  Hardware test 2 covers them.
- `HibernateOnACPower = false` renders through NixOS's unit-option
  serialiser as `false`, which systemd's boolean parser accepts. The
  evaluation check reads the rendered file to be sure.
- This is the first host with `forceImportRoot = false`. The boot editor
  must stay enabled on ilmenite; the plan asserts that by evaluation.
- The hibernation image holds all of RAM, LUKS keys included. It sits inside
  the LUKS swap container, and after a resume it stays there until overwritten
  by swap use. That is the accepted LUKS-swap model.
- A reinstall wipes the laptop. The owner confirms nothing unpushed is on it
  before the wipe.

## Exit criteria

- Config merged to `main`: disko layout, `hibernation.nix`, `default.nix`
  without the force-import line, runbook edits.
- ilmenite reinstalled with the new layout; one prompt on cold boot.
- The six hardware tests pass and are written up.
- `docs/plans/active/scheelite-force-import-root-decision.md` gains a pointer
  to ilmenite as the first host running `false`.
- This plan and its implementation plan move to `docs/plans/completed/`;
  memory updated.

## Follow-ups outside this plan

- TPM2 or FIDO2 enrolment for the LUKS containers with `systemd-cryptenroll`.
- The same policy for malachite, which would mean a module and a reinstall
  there too.
- Re-run the stick test and the hardware tests after a BIOS update.
- `spd5118` resume error: check whether a fix landed upstream before
  silencing it.
