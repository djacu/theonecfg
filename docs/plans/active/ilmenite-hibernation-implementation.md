# ilmenite Hibernation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give ilmenite suspend-then-hibernate with one passphrase, by moving
it to a LUKS swap plus LUKS-wrapped ZFS pool layout, fixing the initrd
ordering, and setting the sleep policy, then reinstalling it and verifying on
the hardware.

**Architecture:** disko gets two LUKS2 containers (`cryptswap`, 68 GB, and
`cryptzroot` holding the unencrypted pool) sharing one passphrase. A new
`hibernation.nix` on the host turns on `boot.zfs.unsafeAllowHibernation`,
flips `forceImportRoot` to `false`, orders the pool import after the resume
unit and the pool container unlock, and sets the systemd, logind, and Plasma
sleep policy. The reinstall reuses the nixos-anywhere runbook with a
host-id pre-seed. Verification is evaluation and build on argentite, then
eight hardware tests driven by the owner and checked read-only over SSH.

**Tech Stack:** NixOS unstable (flake pin `nixos-26.11.20260905.c043004`),
kernel `linuxPackages_6_18`, disko, impermanence, nixos-anywhere 1.13.0,
OpenZFS 2.4.4, systemd 261.2, Plasma 6 (powerdevil 6.7.4).

**Spec:** `docs/plans/active/ilmenite-hibernation.md`

## Global Constraints

- LUKS container names are exactly `cryptswap` and `cryptzroot`; the swap
  partition is `68G`; both containers carry
  `settings = { allowDiscards = true; bypassWorkqueues = true; }` and
  `passwordFile = "/tmp/secret.key"`; the swap content has
  `resumeDevice = true` and `discardPolicy = "once"`.
- The zpool keeps `ashift = "12"`, `autotrim = "on"`, the five datasets and
  their mountpoints, and the `zroot/local/root@empty` snapshot; it has no
  `encryption`, `keyformat`, or `keylocation` property and no key-location
  post-create hook.
- `boot.zfs.unsafeAllowHibernation = true`; `boot.zfs.forceImportRoot = false`;
  `boot.initrd.systemd.services.zfs-import-zroot.after` contains
  `systemd-hibernate-resume.service` and `systemd-cryptsetup@cryptzroot.service`.
- `systemd.sleep.settings.Sleep = { HibernateDelaySec = "3h"; HibernateOnACPower = false; SuspendEstimationSec = "3h"; }`.
- `services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate"`.
- `/etc/xdg/powerdevilrc` holds groups `[AC][SuspendAndShutdown]`,
  `[Battery][SuspendAndShutdown]`, `[LowBattery][SuspendAndShutdown]`, each
  with `SleepMode=3`, and `LidAction=2` in `LowBattery` only.
- `boot.loader.systemd-boot.editor` must evaluate to `true` on ilmenite.
- `networking.hostId` stays `1166a74d`; its file bytes are `4d a7 66 11`.
- The other four hosts' `system.build.toplevel.drvPath` values must not
  change (baseline recorded in Task 0).
- Every commit subject uses the repo's attr-path style and ends with the
  trailer `Assisted-by: Claude Code (claude-fable-5-1)`. No co-author
  trailers.
- Run `nix fmt -- <files>` on every new or edited file; `git diff --exit-code` after formatting must be clean.
- New files must be `git add -N`'d before any `nix eval`/`nix build`, or the
  flake cannot see them.
- Commands the user runs on argentite or ilmenite are fish; commands the
  executor runs through the Bash tool are bash. Each block says which.
- The executor never installs, activates, or rebuilds anything on ilmenite.
  Install and verification steps that touch the laptop are run by the owner;
  the executor prepares commands and checks results read-only over SSH.
- Work happens on branch `djacu/ilmenite-hibernation`. Leave the pre-existing
  uncommitted changes in the working tree alone (`.claude/settings.local.json`,
  the staged `docs/plans/active/scheelite-remote-access.md`, `songs/`).
- `git diff` in this repo uses an external diff tool; add `--no-ext-diff`
  whenever its output is piped.

## Review Focus

1. `HibernateOnACPower = false` must render as the literal line
   `HibernateOnACPower=false` in `/etc/systemd/sleep.conf`; a `0`, `False`,
   or a missing line silently changes the AC behaviour. Pinned to Task 3
   step 4.
1. The powerdevil groups must use KConfig's nested syntax
   `[AC][SuspendAndShutdown]` exactly; a flat `[SuspendAndShutdown]` is
   ignored and the lid stays on plain suspend. Pinned to Task 3 step 4 and
   Task 7 test 6.
1. A passphrase file with a `\r` or trailing space formats both containers
   with a passphrase the boot prompt cannot reproduce; disko strips only
   newlines. Pinned to Task 6 step 2.
1. The installer's `/etc/hostid` must hold the id's bytes in little-endian
   order (`4d a7 66 11`); the wrong order gives the pool a foreign host id
   and the first boot refuses the import. Pinned to Task 6 step 3.
1. A typo in `systemd-cryptsetup@cryptzroot.service` makes the ordering a
   silent no-op; the unit name must match the crypttab entry name. Pinned to
   Task 2 step 4.

______________________________________________________________________

### Task 0: Baseline

**Files:** none modified.

**Interfaces:**

- Produces: the four drvPaths that Task 4 compares against.

- [ ] **Step 1: Confirm the branch and a clean starting point (bash)**

```bash
git branch --show-current
git status --short
```

Expected: `djacu/ilmenite-hibernation`; the status shows only the three
pre-existing entries (`.claude/settings.local.json`,
`docs/plans/active/scheelite-remote-access.md`, `songs/`).

- [ ] **Step 2: Record the fleet baseline (bash)**

```bash
for h in malachite cassiterite argentite scheelite; do
  printf '%s %s\n' "$h" "$(nix eval --raw .#nixosConfigurations.$h.config.system.build.toplevel.drvPath)"
done | tee /tmp/claude-1000/ilmenite-hibernation-baseline.txt
```

Expected: four lines, one store path each. Keep the file; Task 4 reads it.

______________________________________________________________________

### Task 1: Disk layout

**Files:**

- Modify: `nixos-configurations/ilmenite/disko.nix` (whole file)

**Interfaces:**

- Produces: `boot.resumeDevice = "/dev/mapper/cryptswap"`,
  `boot.initrd.luks.devices.{cryptswap,cryptzroot}`, one `swapDevices` entry
  on `/dev/mapper/cryptswap`; Task 2 orders the import after
  `systemd-cryptsetup@cryptzroot.service`, whose name derives from the
  container name set here.

- [ ] **Step 1: Run the gate to see it fail (bash)**

```bash
H=.#nixosConfigurations.ilmenite.config
nix eval --raw "$H.boot.resumeDevice"; echo "<end>"
nix eval --json "$H.boot.initrd.luks.devices" --apply builtins.attrNames
```

Expected: nothing before `<end>`, then `[]`.

- [ ] **Step 2: Replace `disko.nix`**

Write the file with exactly this content:

```nix
{
  disko.devices = {
    disk = {
      disk1 = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_25356W800320";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            swap = {
              size = "68G";
              content = {
                type = "luks";
                name = "cryptswap";
                # Install-time only: nixos-anywhere uploads the passphrase here
                # with --disk-encryption-keys. disko strips the trailing newline.
                passwordFile = "/tmp/secret.key";
                settings = {
                  allowDiscards = true;
                  bypassWorkqueues = true;
                };
                content = {
                  type = "swap";
                  resumeDevice = true;
                  # swapon --discard=once: trims the whole swap at every
                  # activation, so a stale hibernation image does not linger
                  # until overwritten.
                  discardPolicy = "once";
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
          };
        };
      };
    };
    zpool = {
      zroot = {
        type = "zpool";
        rootFsOptions = {
          acltype = "posixacl";
          canmount = "off";
          checksum = "edonr";
          compression = "lz4";
          dnodesize = "auto";
          normalization = "formD";
          relatime = "on";
          xattr = "sa";
        };
        mountpoint = null;
        options = {
          ashift = "12";
          autotrim = "on";
        };

        datasets = {
          local = {
            type = "zfs_fs";
            options.canmount = "off";
          };

          safe = {
            type = "zfs_fs";
            options.canmount = "off";
          };

          "local/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options.mountpoint = "/";
            postCreateHook = ''
              zfs snapshot zroot/local/root@empty
            '';
          };

          "local/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.mountpoint = "/nix";
          };

          "safe/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options.mountpoint = "/home";
          };

          "safe/persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
            options.mountpoint = "/persist";
          };
        };
      };
    };
  };
}
```

- [ ] **Step 3: Format (bash)**

```bash
nix fmt -- nixos-configurations/ilmenite/disko.nix
git --no-pager diff --no-ext-diff --stat
```

Expected: only `disko.nix` listed.

- [ ] **Step 4: Run the gate to see it pass (bash)**

```bash
H=.#nixosConfigurations.ilmenite.config
nix eval --raw "$H.boot.resumeDevice"; echo "<end>"
nix eval --json "$H.boot.initrd.luks.devices" --apply builtins.attrNames
nix eval --json "$H.swapDevices" --apply 'l: map (s: { inherit (s) device discardPolicy; re = s.randomEncryption.enable; }) l'
nix eval --json "$H.boot.initrd.luks.devices" --apply 'd: builtins.mapAttrs (n: v: { inherit (v) device allowDiscards bypassWorkqueues; }) d'
nix eval --json "$H.disko.devices.zpool.zroot.rootFsOptions" --apply builtins.attrNames
nix eval --raw "$H.disko.devices.disk.disk1.content.partitions.swap.size"; echo
```

Expected, line by line:

| Check         | Expected                                                                                                                                                                                                                      |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| resumeDevice  | `/dev/mapper/cryptswap<end>`                                                                                                                                                                                                  |
| luks names    | `["cryptswap","cryptzroot"]`                                                                                                                                                                                                  |
| swapDevices   | `[{"device":"/dev/mapper/cryptswap","discardPolicy":"once","re":false}]`                                                                                                                                                      |
| luks devices  | `{"cryptswap":{"allowDiscards":true,"bypassWorkqueues":true,"device":"/dev/disk/by-partlabel/disk-disk1-swap"},"cryptzroot":{"allowDiscards":true,"bypassWorkqueues":true,"device":"/dev/disk/by-partlabel/disk-disk1-zfs"}}` |
| rootFsOptions | `["acltype","canmount","checksum","compression","dnodesize","normalization","relatime","xattr"]` (no `encryption`, `keyformat`, `keylocation`)                                                                                |
| swap size     | `68G`                                                                                                                                                                                                                         |

- [ ] **Step 5: Commit (bash)**

```bash
git add nixos-configurations/ilmenite/disko.nix
git commit -m "nixosConfigurations.ilmenite: LUKS swap and LUKS-wrapped pool

Two LUKS2 containers sharing one passphrase: cryptswap (68 GB, resume
device, discard once) and cryptzroot holding the pool, which drops ZFS
native encryption. Prepares ilmenite for suspend-then-hibernate; the
layout change is applied by a reinstall.

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 2: Boot and resume

**Files:**

- Create: `nixos-configurations/ilmenite/hibernation.nix`
- Modify: `nixos-configurations/ilmenite/default.nix` (imports list; remove
  the `boot.zfs.forceImportRoot = true;` line and its two comment lines)

**Interfaces:**

- Consumes: container name `cryptzroot` (Task 1) for the unit name
  `systemd-cryptsetup@cryptzroot.service`.

- Produces: `hibernation.nix` as the single home for everything
  hibernation-related; Task 3 appends the sleep policy to it.

- [ ] **Step 1: Run the gate to see it fail (bash)**

```bash
H=.#nixosConfigurations.ilmenite.config
nix eval --json "$H.boot.zfs.unsafeAllowHibernation"
nix eval --json "$H.boot.zfs.forceImportRoot"
nix eval --json "$H.boot.kernelParams" --apply 'l: builtins.elem "nohibernate" l'
```

Expected: `false`, `true`, `true`.

- [ ] **Step 2: Create `hibernation.nix`**

```nix
# Suspend-then-hibernate for ilmenite. Design and verified facts:
# docs/plans/active/ilmenite-hibernation.md.
{
  # The ZFS module puts `nohibernate` on the kernel command line unless this
  # is set, and asserts that the root pool is not force-imported: a forced
  # import under a kernel that is about to resume corrupts the pool.
  boot.zfs.unsafeAllowHibernation = true;

  # First host in the fleet with `false`. The hostid is a fixed hash of the
  # hostname and is present in the initrd, so a crash on this machine imports
  # without -f. Recovery from a refused import is zfs_force=1 typed into the
  # systemd-boot editor, which stays enabled.
  boot.zfs.forceImportRoot = false;

  # Upstream orders nothing between the pool import and the resume unit, so
  # on a resume boot the initrd could import, roll back, and mount the pool
  # before the kernel swaps in the hibernated session. The resume unit binds
  # to the swap mapper, so this also waits for the swap unlock. The second
  # entry waits for the pool container explicitly instead of through the
  # import script's 60-second device retry loop.
  boot.initrd.systemd.services.zfs-import-zroot.after = [
    "systemd-hibernate-resume.service"
    "systemd-cryptsetup@cryptzroot.service"
  ];
}
```

- [ ] **Step 3: Edit `default.nix`**

In `imports`, add `./hibernation.nix` after `./hardware.nix`:

```nix
      imports = [
        ./disko.nix
        ./hardware.nix
        ./hibernation.nix
        ./impermanence.nix

        theonecfg.nixosHardware.framework-intel-core-ultra-series3
      ];
```

Delete these three lines from `config`:

```nix
        # Kept true for parity with the other hosts. Recovery from an unclean
        # pool is zfs_force=1 from the systemd-boot editor, which is enabled.
        boot.zfs.forceImportRoot = true;
```

Then:

```bash
git add -N nixos-configurations/ilmenite/hibernation.nix
nix fmt -- nixos-configurations/ilmenite/hibernation.nix nixos-configurations/ilmenite/default.nix
```

- [ ] **Step 4: Run the gate to see it pass (bash)**

```bash
H=.#nixosConfigurations.ilmenite.config
nix eval --json "$H.boot.zfs.unsafeAllowHibernation"
nix eval --json "$H.boot.zfs.forceImportRoot"
nix eval --json "$H.boot.kernelParams"
nix eval --json "$H.boot.initrd.systemd.services.zfs-import-zroot.after"
nix eval --json "$H.boot.initrd.systemd.services.rollback-root.after"
nix eval --json "$H.boot.loader.systemd-boot.editor"
cat "$(nix build --no-link --print-out-paths "$H.boot.initrd.systemd.contents.\"/etc/crypttab\".source")"
grep -c 'forceImportRoot' nixos-configurations/ilmenite/default.nix
```

Expected:

| Check                  | Expected                                                                                                                                                             |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| unsafeAllowHibernation | `true`                                                                                                                                                               |
| forceImportRoot        | `false`                                                                                                                                                              |
| kernelParams           | a list containing `"resume=/dev/mapper/cryptswap"` and not containing `"nohibernate"`                                                                                |
| import `after`         | contains `"systemd-modules-load.service"`, `"systemd-ask-password-console.service"`, `"systemd-hibernate-resume.service"`, `"systemd-cryptsetup@cryptzroot.service"` |
| rollback-root after    | `["zfs-import-zroot.service"]`                                                                                                                                       |
| editor                 | `true`                                                                                                                                                               |
| crypttab               | two lines; the first field of one is `cryptswap`, of the other `cryptzroot`; both end with `discard,no-read-workqueue,no-write-workqueue`                            |
| default.nix            | `0`                                                                                                                                                                  |

The crypttab first field is the `%i` of `systemd-cryptsetup@%i.service`, so
`cryptzroot` there is what makes the `after` entry real (Review Focus 5).

- [ ] **Step 5: Commit (bash)**

```bash
git add nixos-configurations/ilmenite/hibernation.nix nixos-configurations/ilmenite/default.nix
git commit -m "nixosConfigurations.ilmenite: allow hibernation, import the pool after resume

boot.zfs.unsafeAllowHibernation drops nohibernate and asserts no force
import, so forceImportRoot becomes false on this host (hostid is fixed
and in the initrd; zfs_force=1 from the boot editor is the recovery).
Order zfs-import-zroot after systemd-hibernate-resume.service and the
pool container's cryptsetup unit so a resume boot never imports first.

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 3: Sleep policy

**Files:**

- Modify: `nixos-configurations/ilmenite/hibernation.nix` (append)

**Interfaces:**

- Consumes: `hibernation.nix` (Task 2).

- Produces: `/etc/systemd/sleep.conf`, `/etc/xdg/powerdevilrc`, and the
  logind lid setting that Task 7's tests observe.

- [ ] **Step 1: Run the gate to see it fail (bash)**

```bash
H=.#nixosConfigurations.ilmenite.config
nix eval --raw "$H.environment.etc.\"systemd/sleep.conf\".text" | grep -c 'HibernateDelaySec=3h'
nix eval --json "$H.environment.etc" --apply 'e: e ? "xdg/powerdevilrc"'
```

Expected: `0`, then `false`.

- [ ] **Step 2: Append the policy to `hibernation.nix`**

Insert before the final `}`:

```nix

  # What "sleep" means to systemd. On battery: s2idle, then one wake at 3 h
  # that hibernates; the firmware battery alarm hibernates earlier if the
  # battery exposes one. SuspendEstimationSec matches the delay so the only
  # timed wake is the one that hibernates. On AC the deadline is re-armed at
  # every wake, so a docked laptop wakes briefly every 3 h, checks, and
  # suspends again; unplug it and it hibernates at the next check.
  systemd.sleep.settings.Sleep = {
    HibernateDelaySec = "3h";
    HibernateOnACPower = false;
    SuspendEstimationSec = "3h";
  };

  # Lid handling when no desktop session is running (SDDM screen). Plasma
  # takes the lid over while a session runs.
  services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";

  # Plasma's lid policy. SleepMode 3 = suspend-then-hibernate; LidAction 2 =
  # hibernate at once. /etc/xdg is first in XDG_CONFIG_DIRS, so this is a
  # system default that the user's own powerdevilrc overrides.
  environment.etc."xdg/powerdevilrc".text = ''
    [AC][SuspendAndShutdown]
    SleepMode=3

    [Battery][SuspendAndShutdown]
    SleepMode=3

    [LowBattery][SuspendAndShutdown]
    LidAction=2
    SleepMode=3
  '';
```

Then `nix fmt -- nixos-configurations/ilmenite/hibernation.nix`.

- [ ] **Step 3: Read the file back**

`cat nixos-configurations/ilmenite/hibernation.nix` and confirm the four
settings from Task 2 are still there above the new block and the file ends
with a single `}`.

- [ ] **Step 4: Run the gate to see it pass (bash)**

```bash
H=.#nixosConfigurations.ilmenite.config
nix eval --raw "$H.environment.etc.\"systemd/sleep.conf\".text"
nix eval --raw "$H.environment.etc.\"xdg/powerdevilrc\".text"
nix eval --json "$H.services.logind.settings.Login.HandleLidSwitch"
```

Expected, exactly:

```
[Sleep]
HibernateDelaySec=3h
HibernateOnACPower=false
SuspendEstimationSec=3h
```

then

```
[AC][SuspendAndShutdown]
SleepMode=3

[Battery][SuspendAndShutdown]
SleepMode=3

[LowBattery][SuspendAndShutdown]
LidAction=2
SleepMode=3
```

then `"suspend-then-hibernate"`. The `false` must be the literal word
(Review Focus 1); the group headers must carry both bracket pairs (Review
Focus 2).

- [ ] **Step 5: Commit (bash)**

```bash
git add nixos-configurations/ilmenite/hibernation.nix
git commit -m "nixosConfigurations.ilmenite: suspend-then-hibernate policy

systemd: hibernate 3 h after suspend on battery, not while on AC,
estimation interval 3 h so the only timed wake is the hibernate. logind:
lid closes to suspend-then-hibernate outside a session. Plasma: SleepMode
3 in all profiles via /etc/xdg/powerdevilrc, low battery hibernates at
once.

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 4: Build gate, fleet parity, formatting

**Files:** none modified unless formatting changes something.

**Interfaces:**

- Consumes: `/tmp/claude-1000/ilmenite-hibernation-baseline.txt` (Task 0).

- [ ] **Step 1: Full build of ilmenite (bash)**

```bash
nix build --no-link --print-out-paths .#nixosConfigurations.ilmenite.config.system.build.toplevel
```

Expected: one store path, no error. This is the closure nixos-anywhere will
copy in Task 6.

- [ ] **Step 2: Fleet parity (bash)**

```bash
for h in malachite cassiterite argentite scheelite; do
  printf '%s %s\n' "$h" "$(nix eval --raw .#nixosConfigurations.$h.config.system.build.toplevel.drvPath)"
done | diff - /tmp/claude-1000/ilmenite-hibernation-baseline.txt && echo PARITY-OK
```

Expected: `PARITY-OK`. A difference means something outside
`nixos-configurations/ilmenite/` changed; `git --no-pager diff --no-ext-diff --stat main` must list only files under that directory and under `docs/`.

- [ ] **Step 3: Formatting gate (bash)**

```bash
nix fmt -- nixos-configurations/ilmenite docs/plans/active/ilmenite-hibernation.md docs/plans/active/ilmenite-hibernation-implementation.md
git --no-pager diff --no-ext-diff --exit-code && echo FORMAT-CLEAN
```

Expected: `FORMAT-CLEAN`. If the formatter changed a file, commit it with
subject `nixosConfigurations.ilmenite: format` or `docs/plans: format`.

______________________________________________________________________

### Task 5: Runbook and decision-doc updates

**Files:**

- Modify: `docs/runbooks/install-laptop-with-nixos-anywhere.md` (whole file)
- Modify: `docs/plans/active/scheelite-force-import-root-decision.md`
  (append one paragraph to "Q5")

**Interfaces:**

- Produces: the procedure Task 6 follows verbatim.

- [ ] **Step 1: Run the gate to see it fail (bash)**

```bash
grep -c 'cryptswap' docs/runbooks/install-laptop-with-nixos-anywhere.md
grep -c 'keylocation' docs/runbooks/install-laptop-with-nixos-anywhere.md
```

Expected: `0`, then a number greater than `0`.

- [ ] **Step 2: Replace the runbook**

Write `docs/runbooks/install-laptop-with-nixos-anywhere.md` with exactly:

````markdown
# Install an encrypted, impermanence laptop with nixos-anywhere

Procedure for installing one of this repo's laptop hosts from argentite over
SSH, with the target booted from the NixOS minimal live ISO. All of them use
root rollback and impermanence; they differ in what the disk passphrase
unlocks:

- LUKS hosts (`ilmenite`): every partition except the ESP is a LUKS2
  container with `passwordFile = "/tmp/secret.key"` in `disko.nix`; the ZFS
  pool inside is not natively encrypted. One prompt at boot, shared by the
  containers through systemd's passphrase cache. These hosts run with
  `boot.zfs.forceImportRoot = false`.
- ZFS-native hosts (`malachite`, `cassiterite`): the pool has
  `keylocation = "file:///tmp/secret.key"` at create time and a zpool
  `postCreateHook` of `zfs set keylocation=prompt <pool>`.

First executed for `ilmenite` on 2026-10-03 (ZFS-native) and again for the
LUKS layout; see `docs/plans/active/ilmenite-hibernation.md`.

## Prerequisites

On the target:

1. Secure Boot off in firmware. The 26.05 ISO's boot loader is unsigned GRUB;
   with Secure Boot on, the stick is not listed as bootable.
1. Boot the NixOS minimal live ISO. Wired network is simplest.
1. As the `nixos` user: `sudo passwd root` and set a throwaway password.
1. Note the address: `ip -4 -brief addr`.

On argentite, in the repo root on the branch that adds or changes the host,
with every new file tracked (`git add -N`) and
`nix build .#nixosConfigurations.<host>.config.system.build.toplevel` already
green.

## Procedure (fish, on argentite)

Replace `<host>`, `<ip>`, `<user>`, and `<pool>`.

1. Confirm the disk id in the host's `disko.nix` exists on the target and is
   the intended disk:

   ```fish
   ssh root@<ip> 'ls -l /dev/disk/by-id/ | grep -v -- -part; lsblk -o NAME,SIZE,MODEL,SERIAL /dev/nvme0n1; modprobe zfs && zfs version'
   ```

   The `device` in `disko.nix` must appear in the listing and point at the
   NVMe shown by `lsblk`, and `zfs version` must print a version (the ZFS
   module is loaded on the ISO). Stop if either check fails.

1. Stage the passphrase and the identity files:

   ```fish
   set work (mktemp -d)
   read -s -P 'Disk passphrase: ' diskpass
   printf '%s\n' $diskpass > $work/disk.key
   set -e diskpass
   od -c $work/disk.key | tail -n 2
   install -d -m 0755 $work/extra/persist/etc/ssh
   ssh-keygen -q -t ed25519 -N '' -C <host> -f $work/extra/persist/etc/ssh/ssh_host_ed25519_key
   ssh-keygen -q -t rsa -b 4096 -N '' -C <host> -f $work/extra/persist/etc/ssh/ssh_host_rsa_key
   systemd-id128 new > $work/extra/persist/etc/machine-id
   chmod 0444 $work/extra/persist/etc/machine-id
   ssh-keygen -lf $work/extra/persist/etc/ssh/ssh_host_ed25519_key.pub
   cat $work/extra/persist/etc/machine-id
   ```

   The passphrase must be ASCII only; the initrd prompt uses the US keymap.
   ZFS-native hosts also need at least 8 characters (the OpenZFS minimum,
   checked only at `zpool create`, after the disk is partitioned).

   The `od` output must end with the passphrase's last character followed
   by a single `\n` and nothing else: no `\r`, no trailing space. Both
   consumers drop that newline. disko hands the file to `cryptsetup` as
   `$(cat ...)`, which strips trailing newlines, for `luksFormat` and for
   the open that follows alike; ZFS trims one newline when it reads a key
   file. Either way, the passphrase typed at the boot prompt is the file's
   content without the newline. Record the fingerprint and machine-id for
   the post-install check.

   The keys go under `persist/` because `/etc` on the root dataset is rolled
   back on every boot; `--copy-host-keys` would land them in the wrong place.

1. LUKS hosts only: give the installer the host's ZFS host id before the
   pool is created. The pool records the host id of the system that creates
   it, and these hosts import without `-f`, so the installer must carry the
   host's id. nixos-anywhere exports the pool at the end anyway, but that
   export runs with `|| true`; this makes a swallowed failure harmless.

   ```fish
   scp (nix build --no-link --print-out-paths .#nixosConfigurations.<host>.config.environment.etc.hostid.source) root@<ip>:/etc/hostid
   ssh root@<ip> 'od -An -tx1 /etc/hostid'
   nix build --no-link --print-out-paths .#nixosConfigurations.<host>.config.environment.etc.hostid.source | xargs od -An -tx1
   ```

   The two `od` lines must be identical: the host id's bytes in reverse
   order, `4d a7 66 11` for ilmenite. The ZFS tools and the kernel module
   both read `/etc/hostid` on demand, so no reload is needed.

1. Install:

   ```fish
   read -s -P 'ISO root password: ' -x SSHPASS
   nix run .#nixos-anywhere -- \
     --env-password \
     --flake .#<host> \
     --target-host root@<ip> \
     --disk-encryption-keys /tmp/secret.key $work/disk.key \
     --extra-files $work/extra
   set -e SSHPASS
   ```

   nixos-anywhere sees `VARIANT_ID=installer` and skips kexec, uploads the
   key file, runs disko (destroy, format, mount), copies the closure built on
   argentite, untars the extra files into `/mnt`, runs `nixos-install`,
   exports the pool, and reboots. In the disko output look for, on LUKS
   hosts, one `luksFormat` per container and a `zpool create` line without
   `encryption=`; on ZFS-native hosts, the `zpool create` line and the
   hook's `zfs set keylocation=prompt`. Unplug the USB stick as soon as
   nixos-anywhere prints `Rebooting`, so the firmware boots the new install
   and not the installer.

1. First boot, on the target. LUKS hosts: the initrd asks once,
   `Please enter passphrase for disk cryptswap` or `cryptzroot`, whichever
   unit asks first; the other container unlocks from the cached answer.
   ZFS-native hosts: `Enter key for <pool>`. Log in to Plasma with the
   password, before enrolling any fingerprint.

1. Apply home-manager on the target, from a checkout of the repo:

   ```fish
   nix run --inputs-from . home-manager-unstable -- switch --flake .#<host>-<user>
   ```

## Post-install checks (on the target)

Each line is a command and what it must show.

- `hostid` equals `nix eval --raw .#nixosConfigurations.<host>.config.networking.hostId`.
- `zpool status <pool>` shows `state: ONLINE`.
- LUKS hosts: `zfs get -H -o value encryption <pool>` prints `off`;
  `sudo cryptsetup status cryptswap` and `sudo cryptsetup status cryptzroot`
  both print `is active` with `type: LUKS2` and flags `discards` and
  `no_read_workqueue no_write_workqueue`.
- ZFS-native hosts: `zfs get -H -o value keylocation <pool>` prints `prompt`.
- `swapon --show` lists one `/dev/mapper/` device: `cryptswap` on LUKS hosts.
- `cat /proc/cmdline`: LUKS hosts contain `resume=/dev/mapper/cryptswap` and
  no `nohibernate`; ZFS-native hosts contain `nohibernate` and no `resume=`.
- `lsmod | grep -E '^(xe|framework_laptop|cros_ec_lpcs) '` lists all three.
- `cat /sys/class/power_supply/BAT1/charge_control_end_threshold` prints a number.
- `nix shell .#efibootmgr -c sudo efibootmgr` (efibootmgr is not installed on the host; `sudo` keeps `PATH`) shows `Linux Boot Manager` first in `BootOrder`. A reinstall leaves a second `Linux Boot Manager` entry pointing at the old ESP's partition id; delete it with `nix shell .#efibootmgr -c sudo efibootmgr -b <id> -B` after confirming its partition GUID is not the current ESP's (`lsblk -o NAME,PARTUUID /dev/nvme0n1`).
- `cat /etc/machine-id` equals the staged id; `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` equals the staged fingerprint.
- `systemctl --failed` prints `0 loaded units listed`.
- `fprintd-enroll` succeeds; afterwards `sudo -k; sudo true` accepts a finger.
- `fwupdmgr get-devices` lists the system firmware and the fingerprint reader.
- Speakers, headset jack, Wi-Fi, and Bluetooth each work once.

Optional: delete other stale firmware boot entries with
`nix shell .#efibootmgr -c sudo efibootmgr -b <id> -B`
after confirming each points at a partition that no longer exists.

## Cleanup (fish, on argentite)

Only after the post-install checks pass, since Rollback re-runs the install
step and needs the staged files:

```fish
rm -rf $work
```

Also drop the old host key the laptop had before a reinstall:
`ssh-keygen -R <host>` and `ssh-keygen -R <ip>` for every address it used.

## Rollback

The disk was blank, so a failed install loses nothing. Fix the configuration
and re-run the install step.

If the first boot cannot import the pool: on LUKS hosts, first try
`zfs_force=1` once, typed into the boot entry from the systemd-boot editor
(press `e`), which imports with `-f` for that boot only. If that is not
enough, boot the stick, unlock the pool container, import, export, and
reboot:

```sh
cryptsetup open /dev/disk/by-partlabel/disk-disk1-zfs cryptzroot
zpool import -f <pool>
zpool export <pool>
```

Before importing a hibernation-capable host's pool from the stick, make
sure no hibernation image is waiting on its swap: unlock the swap container
and overwrite the swap header, `cryptsetup open
/dev/disk/by-partlabel/disk-disk1-swap cryptswap && mkswap /dev/mapper/cryptswap`.
Importing the pool elsewhere while an image exists and then letting the next
normal boot resume that image corrupts the pool. Never boot such a host with
`noresume` for the same reason.
````

- [ ] **Step 3: Format and run the gate to see it pass (bash)**

```bash
nix fmt -- docs/runbooks/install-laptop-with-nixos-anywhere.md
grep -c 'cryptswap' docs/runbooks/install-laptop-with-nixos-anywhere.md
grep -c 'keylocation' docs/runbooks/install-laptop-with-nixos-anywhere.md
grep -n 'disk.key\|zfs.key' docs/runbooks/install-laptop-with-nixos-anywhere.md
```

Expected: a number greater than `0`; `2` (both in the ZFS-native bullets, not
as a requirement); only `disk.key` lines, no `zfs.key`.

- [ ] **Step 4: Append to the decision doc**

In `docs/plans/active/scheelite-force-import-root-decision.md`, after the
last paragraph of "### Q5 — Do laptops have the same considerations?"
(the one ending "Decide per-host based on Q3 findings."), add:

```markdown

Update 2026-10: `ilmenite` is the first host running `false`, because
`boot.zfs.unsafeAllowHibernation` asserts it. Its recovery path is
`zfs_force=1` from the systemd-boot editor, which is enabled by default at
the current pin (this doc's Q2 predates that). See
`docs/plans/active/ilmenite-hibernation.md` and the hardware verification
doc it names for how the first boots and the unclean shutdowns went.
```

Then `nix fmt -- docs/plans/active/scheelite-force-import-root-decision.md`.

- [ ] **Step 5: Commit (bash)**

```bash
git add docs/runbooks/install-laptop-with-nixos-anywhere.md
git commit -m "docs/runbooks: install-laptop-with-nixos-anywhere: LUKS hosts

Generalise the passphrase handling to LUKS and ZFS-native hosts, add the
host-id pre-seed for forceImportRoot=false hosts, the post-install checks
for the containers, resume device and command line, the stale EFI entry
after a reinstall, and the rule to invalidate a hibernation image before
importing a pool from the stick.

Assisted-by: Claude Code (claude-fable-5-1)"
git add docs/plans/active/scheelite-force-import-root-decision.md
git commit -m "docs/plans/active: scheelite-force-import-root-decision: note ilmenite runs false

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 6: Reinstall ilmenite (owner-driven)

**Files:** none in the repo. The spec's "Install log" is written in Task 7's
investigation doc.

**Interfaces:**

- Consumes: the runbook (Task 5), the built closure (Task 4).
- Produces: ilmenite running the new layout; its new host-key fingerprint and
  machine-id, recorded for Task 7.

The executor prepares each command block, the owner runs it, and the
executor reads results. The executor does not run `nixos-anywhere`,
`nixos-rebuild`, or `home-manager` against ilmenite.

- [ ] **Step 1: Pre-wipe checks (owner, fish)**

On ilmenite, in the theonecfg clone: `git status --short --branch`.
Expected: nothing unpushed (confirmed once on 2026-10-04; confirm again).
Then on argentite:

```fish
ssh-keygen -R ilmenite; ssh-keygen -R 10.0.10.83; ssh-keygen -R 10.0.10.84; ssh-keygen -R 10.0.10.85
```

Also remove any other address ilmenite has used that `grep ilmenite ~/.ssh/known_hosts` or a later `ssh` warning reveals.

- [ ] **Step 2: Boot the stick and stage (owner, fish)**

Runbook Prerequisites, then Procedure steps 1 and 2 with `<host>` =
`ilmenite`. The `od` line must end in the passphrase's last character then
`\n` only (Review Focus 3). Paste the `od` tail, the fingerprint, and the
machine-id into the chat; the executor records them.

- [ ] **Step 3: Host-id pre-seed (owner, fish)**

Runbook Procedure step 3. Expected: both `od` lines print `4d a7 66 11`
(Review Focus 4). Stop if they differ.

- [ ] **Step 4: Install (owner, fish)**

Runbook Procedure step 4. Watch for two `luksFormat` lines and a `zpool create` without `encryption=`. Unplug the stick at `Rebooting`.

- [ ] **Step 5: First boot and home-manager (owner)**

Runbook Procedure steps 5 and 6. Report: how many passphrase prompts
appeared (expected: one), and which container's name the prompt showed.

- [ ] **Step 6: Post-install checks (owner on the target; executor read-only over SSH)**

Owner: run the runbook's Post-install checks and paste results. Executor,
from argentite, with `<ip>` the new address (find it by the staged
fingerprint if DHCP moved it):

```bash
ssh djacu@<ip> 'cat /proc/cmdline; swapon --show; zfs get -H -o value encryption zroot; hostid; cat /etc/machine-id; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub; systemctl --failed; busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspendThenHibernate; cat /sys/class/power_supply/BAT1/alarm; cat /etc/systemd/sleep.conf; cat /etc/xdg/powerdevilrc'
```

Expected: `resume=/dev/mapper/cryptswap` and no `nohibernate`; one
`/dev/mapper/cryptswap` swap of 68G; `off`; `1166a74d`; the staged
machine-id and fingerprint; `0 loaded units listed`; `s "yes"`; a number
(record it: greater than zero means systemd will use the firmware alarm
path); the four-line sleep.conf and the powerdevilrc from Task 3.

______________________________________________________________________

### Task 7: Hardware verification

**Files:**

- Create: `docs/investigations/ilmenite-hibernation-verification.md`

**Interfaces:**

- Consumes: ilmenite on the new layout (Task 6).

- Produces: the written results the spec's exit criteria require.

- [ ] **Step 1: Create the doc with the procedure and an empty results table**

Write `docs/investigations/ilmenite-hibernation-verification.md`:

````markdown
# ilmenite hibernation verification

**Status:** In progress
**Date:** <date of the first test>
**Owner:** djacu
**Context:** Task 7 of `docs/plans/active/ilmenite-hibernation-implementation.md`; design in `docs/plans/active/ilmenite-hibernation.md`

## Install log

- Staged fingerprint: <fingerprint>; machine-id: <id>.
- Host-id pre-seed: both `od` lines `4d a7 66 11`.
- Install: <date>, <duration>, prompts at first boot: <n>, prompt named
  <cryptswap|cryptzroot>.
- Post-install checks: <all passed | list>.
- `BAT1/alarm` at first boot: <value>.

## Tests

The owner runs the (ilmenite) commands in fish on the laptop; the executor
runs the (argentite) commands in bash over SSH, read-only.

### 1. Cold boot ordering

(ilmenite) Reboot, count prompts. Then:

```fish
journalctl -b -o short-monotonic | grep -E 'cryptsetup@|hibernate-resume|zfs-import-zroot|rollback-root' | head -n 20
```

Pass: one prompt; both `systemd-cryptsetup@` units finish before
`systemd-hibernate-resume.service` starts, which finishes before
`zfs-import-zroot.service` starts, which finishes before
`rollback-root.service`. No "Found ordering cycle" line in `journalctl -b -p warning`.

### 2. Hibernate and resume, cold ARC and warm ARC

(ilmenite)

```fish
date -u > /tmp/hibtest-marker; cat /tmp/hibtest-marker; cat /proc/uptime
systemctl hibernate
```

Power on. One prompt. Then:

```fish
cat /tmp/hibtest-marker; cat /proc/uptime
sudo dmesg | grep -i -E 'ACPI (BIOS )?Error|_WAK|BERT|Hardware Error' | head
sudo dmesg | grep -i -E 'sleep state S4|failed to restore|dpm_run_callback|spd5118' | tail -n 8
```

Pass: marker from before the hibernate (a cold boot would have rolled
`/tmp` back), uptime continued, no ACPI errors, S4 entry and wake lines
present. Note whether `spd5118` still returns `-6`.

Warm ARC: write a random file of 30 GB, read it twice, check the ARC size,
then hibernate again the same way:

```fish
dd if=/dev/urandom of=/home/djacu/arcfill bs=1M count=30000 status=progress
cat /home/djacu/arcfill > /dev/null; cat /home/djacu/arcfill > /dev/null
grep -E '^(size|c_max) ' /proc/spl/kstat/zfs/arcstats
date -u > /tmp/hibtest-marker; systemctl hibernate
```

After the resume: marker present, `sudo dmesg | grep -i -E 'hibernation|Image'
| tail -n 12` shows the image pages count and no "Image allocation" or
"Not enough" error. Then `rm /home/djacu/arcfill`.

### 3. suspend-then-hibernate with a short delay

(ilmenite) Runtime-only overrides, no rebuild:

```fish
sudo mkdir -p /run/systemd/sleep.conf.d
printf '[Sleep]\nHibernateDelaySec=2min\nSuspendEstimationSec=2min\nHibernateOnACPower=yes\n' | sudo tee /run/systemd/sleep.conf.d/test.conf
sudo mkdir -p /run/systemd/system/systemd-suspend-then-hibernate.service.d
printf '[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\n' | sudo tee /run/systemd/system/systemd-suspend-then-hibernate.service.d/debug.conf
sudo systemctl daemon-reload
date -u > /tmp/hibtest-marker; systemctl suspend-then-hibernate
```

Expected: suspend; after about two minutes the machine wakes by itself and
powers off (hibernated). Power on, one prompt, session back. Then:

```fish
cat /tmp/hibtest-marker
journalctl -b -u systemd-suspend-then-hibernate.service --no-pager | grep -i -E 'alarm|APM Timer|Manual wakeup|Timer fired|estimat|hibernat|suspend' | head -n 30
sudo rm /run/systemd/sleep.conf.d/test.conf /run/systemd/system/systemd-suspend-then-hibernate.service.d/debug.conf; sudo systemctl daemon-reload
```

Pass: marker present; the journal shows which path systemd took (firmware
alarm or timer) and, on the alarm path, "Woken by APM Timer" rather than a
manual-wakeup exit. If the alarm path misjudged the wake, record it; the
fix is a udev rule writing `0` to `/sys/class/power_supply/BAT1/alarm`,
which forces the timer path, and it becomes a follow-up commit.

### 4. Lid on battery

(ilmenite) Unplug. `cat /sys/class/power_supply/BAT1/charge_now`, close the
lid for ten minutes, open it. Pass: `journalctl -b -u
systemd-suspend-then-hibernate.service` shows one suspend entry and no
hibernate; `charge_now` dropped by about 0.1 %.

Overnight: `cat /sys/class/power_supply/BAT1/charge_now; date`, close the
lid unplugged, leave it. In the morning the machine is off. Power on, one
prompt, session back; `charge_now` again. Pass: hibernated after about 3 h
(the journal's last entries before the hibernate are about 3 h after the
lid close), total drop about 1.5 % plus the hibernate.

### 5. Lid on AC, then unplug

(ilmenite) Plugged in through the hub, no external monitor. Close the lid
for more than three hours, open it:

```fish
journalctl -b -u systemd-suspend-then-hibernate.service --since -5h --no-pager | grep -i -E 'suspend|wake|timer|hibernat' | head -n 30
```

Pass: a wake about every three hours, each followed by a new suspend, no
hibernate. Then close the lid again, unplug the hub after ten minutes, and
leave it. Pass: within three hours the machine is off; power on, one prompt,
session back.

### 6. logind and Plasma agree

(ilmenite)

```fish
busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspendThenHibernate
cat /sys/class/power_supply/BAT1/alarm
```

Pass: `s "yes"`. System Settings, Power Management, "When sleeping, enter"
shows "Standby, then hibernate" for both the AC and the battery tabs, and
the low-battery tab's lid action shows Hibernate. Record the alarm value.

### 7. KVM, lid closed

(ilmenite on the hub with the KVM's monitor) Close the lid: nothing happens
(clamshell). Switch the KVM away and wait a minute. Record whether the
laptop suspended (the monitor disappeared) or kept running (EDID emulation).
If it suspended, press a key on the hub keyboard: record whether that woke
it. Then, with the lid still closed, `systemctl hibernate` from the laptop
over SSH, power on, and record where the passphrase prompt appeared,
internal panel or external monitor.

### 8. Discard on cold boot

(ilmenite) After any cold boot: `journalctl -b -u 'dev-mapper-cryptswap.swap'
--no-pager`. Pass: the swap unit activated; `swapon --show` lists it.
`sudo cat /sys/block/dm-0/queue/discard_granularity` greater than `0` for the
swap mapper (find its `dm-N` with `ls -l /dev/mapper/cryptswap`).

## Results

| Test | Date | Result | Notes |
| ---- | ---- | ------ | ----- |
|      |      |        |       |

## Decision

<Pass or fail against the spec's exit criteria, and anything changed as a result.>
````

Then `git add -N docs/investigations/ilmenite-hibernation-verification.md`
and `nix fmt -- docs/investigations/ilmenite-hibernation-verification.md`.

- [ ] **Step 2: Run the tests (owner) and record (executor)**

Walk tests 1 to 8 with the owner, one at a time, in the order written. For
each, the executor fills the results row and replaces the install-log
placeholders with the values from Task 6. Tests 4 and 5 span many hours; the
doc is committed with `Status: In progress` between them.

- [ ] **Step 3: Commit after each session (bash)**

```bash
git add docs/investigations/ilmenite-hibernation-verification.md
git commit -m "docs/investigations: ilmenite hibernation verification: <tests done>

Assisted-by: Claude Code (claude-fable-5-1)"
```

When all eight have a result, set `Status: Complete`, write the Decision,
and commit with `<tests done>` = `complete`.

______________________________________________________________________

### Task 8: Close out

**Files:**

- Move: `docs/plans/active/ilmenite-hibernation.md` and
  `docs/plans/active/ilmenite-hibernation-implementation.md` to
  `docs/plans/completed/`
- Modify: the spec's `**Status:**` line

**Interfaces:**

- Consumes: a complete verification doc (Task 7).

- [ ] **Step 1: Move and mark (bash)**

```bash
git mv docs/plans/active/ilmenite-hibernation.md docs/plans/completed/ilmenite-hibernation.md
git mv docs/plans/active/ilmenite-hibernation-implementation.md docs/plans/completed/ilmenite-hibernation-implementation.md
sed -i 's|^\*\*Status:\*\* .*|**Status:** Completed <date>; verified on hardware, results in `docs/investigations/ilmenite-hibernation-verification.md`|' docs/plans/completed/ilmenite-hibernation.md
sed -i 's|docs/plans/active/ilmenite-hibernation|docs/plans/completed/ilmenite-hibernation|g' docs/plans/completed/ilmenite-hibernation-implementation.md docs/investigations/ilmenite-hibernation-verification.md docs/plans/active/scheelite-force-import-root-decision.md docs/runbooks/install-laptop-with-nixos-anywhere.md nixos-configurations/ilmenite/hibernation.nix
nix fmt -- docs/plans/completed/ilmenite-hibernation.md docs/plans/completed/ilmenite-hibernation-implementation.md docs/investigations/ilmenite-hibernation-verification.md docs/plans/active/scheelite-force-import-root-decision.md docs/runbooks/install-laptop-with-nixos-anywhere.md nixos-configurations/ilmenite/hibernation.nix
grep -rn 'plans/active/ilmenite-hibernation' docs nixos-configurations; echo "<end>"
```

Expected: nothing before `<end>`.

- [ ] **Step 2: Commit (bash)**

```bash
git add -A docs/plans docs/investigations docs/runbooks nixos-configurations/ilmenite/hibernation.nix
git commit -m "docs/plans: complete ilmenite hibernation

Assisted-by: Claude Code (claude-fable-5-1)"
```

Check with `git show --stat HEAD` that only the intended files are in the
commit; the pre-existing `docs/plans/active/scheelite-remote-access.md`
intent-to-add entry must not be swept in. If it was, `git rm --cached` it,
amend, and `git add -N` it again.

- [ ] **Step 3: Finish the branch**

Use superpowers:finishing-a-development-branch: push `djacu/ilmenite-hibernation`
and open the PR against `main` with a body that lists the layout change,
the reinstall, the policy, and the verification doc, ending with the single
line `Assisted-by: Claude Code (claude-fable-5-1)`. Update the memory file
`project_ilmenite_hibernation_notes.md` and the `MEMORY.md` index line to
"done" with the date and the PR number.
