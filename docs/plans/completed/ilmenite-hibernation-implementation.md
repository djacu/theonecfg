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
eight hardware tests driven by the owner and checked read-only over SSH,
with one conditional fix task for the firmware battery-alarm path.

**Tech Stack:** NixOS unstable (flake pin `nixos-26.11.20260905.c043004`),
kernel `linuxPackages_6_18`, disko, impermanence, nixos-anywhere 1.13.0,
OpenZFS 2.4.4, systemd 261.2, Plasma 6 (powerdevil 6.7.4).

**Spec:** `docs/plans/completed/ilmenite-hibernation.md`

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
- Never deploy this branch to ilmenite except through the Task 6 reinstall.
  Tasks 1 to 3 describe a disk layout the installed ilmenite does not have;
  a `nixos-rebuild` of any of them onto it would make the initrd wait for
  LUKS containers that do not exist.
- Every commit subject uses the repo's attr-path style and ends with the
  trailer `Assisted-by: Claude Code (claude-fable-5-1)`. No co-author
  trailers.
- Run `nix fmt -- <files>` on every new or edited file; afterwards
  `git --no-pager diff --no-ext-diff --exit-code -- <those files>` must be
  clean. Always scope diffs with explicit pathspecs: the working tree
  carries unrelated changes (`.claude/settings.local.json`, the
  intent-to-add `docs/plans/active/scheelite-remote-access.md`, `songs/`)
  that make an unscoped `--exit-code` fail forever. Leave those alone and
  never sweep them into a commit.
- New files must be `git add -N`'d before any `nix eval`/`nix build`, or the
  flake cannot see them.
- Commands the user runs on argentite or ilmenite are fish; commands the
  executor runs through the Bash tool are bash. Each block says which.
- The executor never installs, activates, or rebuilds anything on ilmenite.
  Install, switch, and verification steps that touch the laptop are run by
  the owner; the executor prepares commands and checks results read-only
  over SSH.
- Work happens on branch `djacu/ilmenite-hibernation`.
- `git diff` in this repo uses an external diff tool; add `--no-ext-diff`
  whenever its output is piped or its exit code is used.
- The executor's scratch file for this plan is
  `/tmp/claude-1000/ilmenite-hibernation-baseline.txt`, outside the
  per-session scratchpad on purpose: it must survive a session change, and
  the repo has no git-ignored workspace directory.

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
   newlines. Pinned to Task 6 step 3.
1. The installer's `/etc/hostid` must hold the id's bytes in little-endian
   order (`4d a7 66 11`) in a real file; the installer ships it as a symlink
   into its read-only store, so an overwrite in place fails and leaves the
   installer's own id. Pinned to Task 6 step 4.
1. A typo in `systemd-cryptsetup@cryptzroot.service` makes the ordering a
   silent no-op; the unit name must match the crypttab entry name. Pinned to
   Task 2 step 4.
1. `swapon --show` prints the mapper's `/dev/dm-N` name, not
   `/dev/mapper/cryptswap`; a check that greps for the mapper path fails on a
   correct system. Pinned to Task 6 step 7 and the runbook's post-install
   checks.
1. `discardPolicy = "once"` must reach the swap unit as `Options=defaults,discard=once`;
   a dropped option leaves old image ciphertext on the drive without any
   visible symptom. Pinned to Task 7 test 8.

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

This task's commit on its own describes a config with both `resume=` and
`nohibernate` on the command line and `forceImportRoot` still `true`. That
evaluates cleanly and is never deployed (Global Constraints); Task 2
completes the picture.

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
git --no-pager diff --no-ext-diff --stat -- nixos-configurations/ilmenite
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
nix eval --raw "$H.environment.etc.fstab.text" | grep 'cryptswap none swap'
```

Expected, line by line (JSON keys come out alphabetical):

| Check           | Expected                                                                                                                                                                                                                      |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| resumeDevice    | `/dev/mapper/cryptswap<end>`                                                                                                                                                                                                  |
| luks names      | `["cryptswap","cryptzroot"]`                                                                                                                                                                                                  |
| swapDevices     | `[{"device":"/dev/mapper/cryptswap","discardPolicy":"once","re":false}]`                                                                                                                                                      |
| luks devices    | `{"cryptswap":{"allowDiscards":true,"bypassWorkqueues":true,"device":"/dev/disk/by-partlabel/disk-disk1-swap"},"cryptzroot":{"allowDiscards":true,"bypassWorkqueues":true,"device":"/dev/disk/by-partlabel/disk-disk1-zfs"}}` |
| rootFsOptions   | `["acltype","canmount","checksum","compression","dnodesize","normalization","relatime","xattr"]` (no `encryption`, `keyformat`, `keylocation`)                                                                                |
| swap size       | `68G`                                                                                                                                                                                                                         |
| fstab swap line | `/dev/mapper/cryptswap none swap defaults,discard=once` (artefact-level check for Review Focus 7)                                                                                                                             |

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
  hibernation-related; Task 3 appends the sleep policy to it, Task 7a may
  append a udev rule.

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
# docs/plans/completed/ilmenite-hibernation.md.
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
nix eval --json "$H.warnings"
grep -c 'forceImportRoot' nixos-configurations/ilmenite/default.nix || true
```

Expected:

| Check                  | Expected                                                                                                                                             |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| unsafeAllowHibernation | `true`                                                                                                                                               |
| forceImportRoot        | `false`                                                                                                                                              |
| kernelParams           | a list containing `"resume=/dev/mapper/cryptswap"` and not containing `"nohibernate"`                                                                |
| import `after`         | `["systemd-modules-load.service","systemd-ask-password-console.service","systemd-hibernate-resume.service","systemd-cryptsetup@cryptzroot.service"]` |
| rollback-root after    | `["zfs-import-zroot.service"]`                                                                                                                       |
| editor                 | `true`                                                                                                                                               |
| crypttab               | two lines; the first field of one is `cryptswap`, of the other `cryptzroot`; both end with `discard,no-read-workqueue,no-write-workqueue`            |
| warnings               | `[]`                                                                                                                                                 |
| default.nix            | `0`                                                                                                                                                  |

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
nix eval --raw "$H.environment.etc.\"systemd/sleep.conf\".text" | grep -c 'HibernateDelaySec=3h' || true
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
nix eval --raw "$H.environment.etc.\"systemd/sleep.conf\".text" | od -c | tail -n 4
nix eval --raw "$H.environment.etc.\"systemd/sleep.conf\".text"
nix eval --raw "$H.environment.etc.\"xdg/powerdevilrc\".text"
nix eval --json "$H.services.logind.settings.Login.HandleLidSwitch"
```

Expected: the `od` tail ends with `3 h \n \n` (the section serialiser adds
one trailing empty line); the text, exactly, plus that trailing empty line:

```
[Sleep]
HibernateDelaySec=3h
HibernateOnACPower=false
SuspendEstimationSec=3h
```

then, byte-exact:

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

Expected: `PARITY-OK`. If it differs: stop, run
`git --no-pager diff --no-ext-diff --stat main -- . ':!docs'`, which must
list only files under `nixos-configurations/ilmenite/`; anything else is a
stray edit to revert before continuing. If only ilmenite files are listed
and the paths still differ, the baseline was taken on a different pin;
re-run Task 0 step 2 on `main` in a worktree and compare again.

- [ ] **Step 3: Formatting gate (bash)**

```bash
nix fmt -- nixos-configurations/ilmenite docs/plans/completed/ilmenite-hibernation.md docs/plans/completed/ilmenite-hibernation-implementation.md
git --no-pager diff --no-ext-diff --exit-code -- nixos-configurations/ilmenite docs/plans/completed/ilmenite-hibernation.md docs/plans/completed/ilmenite-hibernation-implementation.md && echo FORMAT-CLEAN
```

Expected: `FORMAT-CLEAN`. If the formatter changed a file, commit only that
file:

```bash
git add <file>
git commit -m "<nixosConfigurations.ilmenite|docs/plans>: format

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 5: Runbook, decision-doc update, push

**Files:**

- Modify: `docs/runbooks/install-laptop-with-nixos-anywhere.md` (whole file)
- Modify: `docs/plans/active/scheelite-force-import-root-decision.md`
  (append one paragraph to "Q5")

**Interfaces:**

- Produces: the procedure Task 6 follows verbatim; the branch on the remote
  so the laptop can clone it.

- [ ] **Step 1: Run the gate to see it fail (bash)**

```bash
grep -c 'cryptswap' docs/runbooks/install-laptop-with-nixos-anywhere.md || true
grep -c 'must use .keylocation' docs/runbooks/install-laptop-with-nixos-anywhere.md || true
```

Expected: `0`, then `1`.

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
LUKS layout; see `docs/plans/completed/ilmenite-hibernation.md`.

## Prerequisites

On the target:

1. Secure Boot off in firmware. The 26.05 ISO's boot loader is unsigned GRUB;
   with Secure Boot on, the stick is not listed as bootable.
1. Boot the NixOS minimal live ISO from a port on the laptop itself, not a
   hub. Wired network is simplest.
1. As the `nixos` user: `sudo passwd root` and set a throwaway password.
1. Note the address: `ip -4 -brief addr`.

On argentite, in the repo root on the branch that adds or changes the host,
with every new file tracked (`git add -N`) and
`nix build .#nixosConfigurations.<host>.config.system.build.toplevel` already
green.

## Procedure (fish, on argentite)

Replace `<host>`, `<ip>`, `<user>`, and `<pool>`. The live ISO has a fresh
host key on every boot, so talk to it without recording that key; the two
aliases below do what nixos-anywhere itself does:

```fish
alias isossh 'ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no'
alias isoscp 'scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no'
```

1. Confirm the disk id in the host's `disko.nix` exists on the target and is
   the intended disk:

   ```fish
   isossh root@<ip> 'ls -l /dev/disk/by-id/ | grep -v -- -part; lsblk -o NAME,SIZE,MODEL,SERIAL /dev/nvme0n1; modprobe zfs && zfs version'
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
   The ISO ships its own `/etc/hostid` as a symlink into its read-only
   store, so the link is removed and a real file put in its place:

   ```fish
   isoscp (nix build --no-link --print-out-paths .#nixosConfigurations.<host>.config.environment.etc.hostid.source) root@<ip>:/root/hostid
   isossh root@<ip> 'rm -f /etc/hostid && mv /root/hostid /etc/hostid && od -An -tx1 /etc/hostid'
   nix build --no-link --print-out-paths .#nixosConfigurations.<host>.config.environment.etc.hostid.source | xargs od -An -tx1
   ```

   The two `od` lines must be identical: the host id's bytes in reverse
   order, `4d a7 66 11` for ilmenite. The ZFS tools and the kernel module
   both read `/etc/hostid` on demand, so no reload is needed. Stop if the
   lines differ.

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
   unmounts, exports the pool, and reboots about six seconds after printing
   `Rebooting`. In the disko output look for, on LUKS hosts, one
   `luksFormat` per container and a `zpool create` line without
   `encryption=`; on ZFS-native hosts, the `zpool create` line and the
   hook's `zfs set keylocation=prompt`. Leave the stick in until the screen
   goes dark for the reboot: it is the live system's root, and the unmount
   and export still need it. Then pull it, or pick the NVMe entry in the
   firmware boot menu.

1. First boot, on the target. LUKS hosts: the initrd asks once,
   `Please enter passphrase for disk cryptswap` or `cryptzroot`, whichever
   unit asks first; the other container unlocks from the cached answer.
   ZFS-native hosts: `Enter key for <pool>`. Log in to Plasma with the
   password, before enrolling any fingerprint.

1. Apply home-manager on the target, from a checkout of the repo on the
   branch that was installed:

   ```fish
   nix run --inputs-from . home-manager-unstable -- switch --flake .#<host>-<user>
   ```

## Post-install checks (on the target)

Each line is a command and what it must show.

- `hostid` equals `nix eval --raw .#nixosConfigurations.<host>.config.networking.hostId`.
- `zpool status <pool>` shows `state: ONLINE`.
- LUKS hosts: `zfs get -H -o value encryption <pool>` prints `off`;
  `sudo cryptsetup status cryptswap` and `sudo cryptsetup status cryptzroot`
  both print `is active and is in use`, `type:    LUKS2`, and
  `flags:   discards no_read_workqueue no_write_workqueue`.
- ZFS-native hosts: `zfs get -H -o value keylocation <pool>` prints `prompt`.
- `swapon --show` lists one partition entry named `/dev/dm-N` (the mapper's
  kernel name, not the `/dev/mapper/` alias); on LUKS hosts
  `ls -l /dev/mapper/cryptswap` points at that same `dm-N` and the size is
  68G.
- LUKS hosts: `systemctl show -p Options dev-mapper-cryptswap.swap` prints
  `Options=defaults,discard=once`.
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
enough, boot the stick and repair from there, in this order.

First, on a host that can hibernate, make sure no hibernation image is
waiting on its swap. Importing the pool elsewhere while an image exists, and
then letting the next normal boot resume that image, corrupts the pool. The
same applies to booting such a host with `noresume`: never do it while an
image may exist. Unlock the swap container and overwrite the swap header,
which drops any image:

```sh
cryptsetup open /dev/disk/by-partlabel/disk-disk1-swap cryptswap
mkswap /dev/mapper/cryptswap
```

Then import without mounting (`-N`: the datasets' mountpoints are `/`,
`/nix`, and `/home`, and a mounting import would cover the live system's own
directories), export, and reboot:

```sh
cryptsetup open /dev/disk/by-partlabel/disk-disk1-zfs cryptzroot
zpool import -f -N <pool>
zpool export <pool>
```

ZFS-native hosts skip the `cryptsetup` lines and use the same `-N` import.
````

- [ ] **Step 3: Format and run the gate to see it pass (bash)**

```bash
nix fmt -- docs/runbooks/install-laptop-with-nixos-anywhere.md
grep -c 'cryptswap' docs/runbooks/install-laptop-with-nixos-anywhere.md || true
grep -c 'must use .keylocation' docs/runbooks/install-laptop-with-nixos-anywhere.md || true
grep -c 'keylocation' docs/runbooks/install-laptop-with-nixos-anywhere.md || true
grep -n 'disk.key\|zfs.key' docs/runbooks/install-laptop-with-nixos-anywhere.md
grep -c 'import -f -N' docs/runbooks/install-laptop-with-nixos-anywhere.md || true
```

Expected: a number greater than `0`; `0`; `4` (the ZFS-native bullet, the
install-log sentence, the post-install check, and `keylocation = "file`, all
descriptive, none a requirement); only `disk.key` lines, no `zfs.key`; `1`.

- [ ] **Step 4: Append to the decision doc**

In `docs/plans/active/scheelite-force-import-root-decision.md`, after the
last paragraph of "### Q5 — Do laptops have the same considerations?"
(the one ending "Decide per-host based on Q3 findings."), add:

```markdown

Update 2026-10: `ilmenite` is the first host running `false`, because
`boot.zfs.unsafeAllowHibernation` asserts it. Its recovery path is
`zfs_force=1` from the systemd-boot editor, which is enabled by default at
the current pin (this doc's Q2 predates that). See
`docs/plans/completed/ilmenite-hibernation.md` and the hardware verification
doc it names for how the first boots and the unclean shutdowns went.
```

Then `nix fmt -- docs/plans/active/scheelite-force-import-root-decision.md`.

- [ ] **Step 5: Commit (bash)**

```bash
git add docs/runbooks/install-laptop-with-nixos-anywhere.md
git commit -m "docs/runbooks: install-laptop-with-nixos-anywhere: LUKS hosts

Generalise the passphrase handling to LUKS and ZFS-native hosts, add the
host-id pre-seed for forceImportRoot=false hosts, the post-install checks
for the containers, resume device, swap options and command line, the
stale EFI entry after a reinstall, and a Rollback that invalidates a
hibernation image and imports without mounting.

Assisted-by: Claude Code (claude-fable-5-1)"
git add docs/plans/active/scheelite-force-import-root-decision.md
git commit -m "docs/plans/active: scheelite-force-import-root-decision: note ilmenite runs false

Assisted-by: Claude Code (claude-fable-5-1)"
```

- [ ] **Step 6: Push the branch (bash)**

The laptop clones this branch after the reinstall, and Task 7a may need a
`nixos-rebuild switch` from it. The owner approved pushing this branch when
approving the plan.

```bash
git push -u origin djacu/ilmenite-hibernation
```

Expected: the branch is on the remote. `main` keeps describing the old disk
layout until the PR in Task 8 merges; that is deliberate, since ilmenite is
verified on the branch first, the same way the bringup went.

______________________________________________________________________

### Task 6: Reinstall ilmenite (owner-driven)

**Files:**

- Create: `docs/investigations/ilmenite-hibernation-verification.md`
  (skeleton with the install log; Task 7 fills the tests)

**Interfaces:**

- Consumes: the runbook (Task 5), the built closure (Task 4), the pushed
  branch (Task 5 step 6).
- Produces: ilmenite running the new layout; its new host-key fingerprint,
  machine-id, prompt count, install times, and `BAT1/alarm` value, written
  into the verification doc's install log.

The executor prepares each command block, the owner runs it, and the
executor reads results. The executor does not run `nixos-anywhere`,
`nixos-rebuild`, or `home-manager` against ilmenite.

- [ ] **Step 1: Create the verification doc skeleton**

Write `docs/investigations/ilmenite-hibernation-verification.md` with the
full text given in Task 7 step 1, then `git add -N` it and
`nix fmt -- docs/investigations/ilmenite-hibernation-verification.md`. The
install-log fields are filled in during this task as results arrive, so a
session break loses nothing.

- [ ] **Step 2: Pre-wipe checks (owner, fish)**

On ilmenite, in the theonecfg clone: `git status --short --branch`.
Expected: nothing unpushed (confirmed once on 2026-10-04; confirm again).
Then on argentite:

```fish
ssh-keygen -R ilmenite; ssh-keygen -R 10.0.10.83; ssh-keygen -R 10.0.10.84; ssh-keygen -R 10.0.10.85
```

Most of these are no-ops; they remove whatever old ilmenite key is recorded.
The ISO itself is never recorded, since the runbook's aliases discard its
key.

- [ ] **Step 3: Boot the stick and stage (owner, fish)**

Runbook Prerequisites, then Procedure steps 1 and 2 with `<host>` =
`ilmenite`. The `od` line must end in the passphrase's last character then
`\n` only (Review Focus 3). Paste the `od` tail, the fingerprint, and the
machine-id into the chat; the executor writes them into the install log.

- [ ] **Step 4: Host-id pre-seed (owner, fish)**

Runbook Procedure step 3. Expected: both `od` lines print `4d a7 66 11`
(Review Focus 4). Stop if they differ; the usual cause is the ISO's
symlinked `/etc/hostid` not having been removed.

- [ ] **Step 5: Install (owner, fish)**

Note the time, then Runbook Procedure step 4. Watch for two `luksFormat`
lines and a `zpool create` without `encryption=`. Leave the stick in until
the screen goes dark. Note the time again; the install log records start,
end, and anything disko or nixos-install printed that looked wrong.

- [ ] **Step 6: First boot and home-manager (owner)**

Runbook Procedure steps 5 and 6, cloning branch `djacu/ilmenite-hibernation`
on the laptop. Report: how many passphrase prompts appeared (expected: one),
and which container's name the prompt showed.

- [ ] **Step 7: Post-install checks (owner on the target; executor read-only over SSH)**

Owner: run the runbook's Post-install checks and paste results. Executor,
from argentite, with `<ip>` the new address (find it by the staged
fingerprint if DHCP moved it):

```bash
ssh djacu@<ip> 'cat /proc/cmdline; swapon --show; ls -l /dev/mapper/cryptswap; systemctl show -p Options dev-mapper-cryptswap.swap; zfs get -H -o value encryption zroot; hostid; cat /etc/machine-id; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub; systemctl --failed; busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspendThenHibernate; cat /sys/class/power_supply/BAT1/alarm; cat /etc/systemd/sleep.conf; cat /etc/xdg/powerdevilrc'
```

Expected: `resume=/dev/mapper/cryptswap` and no `nohibernate`; one
`/dev/dm-N` partition swap of 68G, and the `ls -l` resolving to that `dm-N`
(Review Focus 6); `Options=defaults,discard=once`; `off`; `1166a74d`; the staged
machine-id and fingerprint; `0 loaded units listed`; `s "yes"`; a number
(record it in the install log: greater than zero means systemd will use the
firmware alarm path, which decides whether Task 7a is needed); the four-line
sleep.conf and the powerdevilrc from Task 3.

- [ ] **Step 8: Commit the install log (bash)**

```bash
git add docs/investigations/ilmenite-hibernation-verification.md
git commit -m "docs/investigations: ilmenite hibernation verification: install log

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 7: Hardware verification

**Files:**

- Modify: `docs/investigations/ilmenite-hibernation-verification.md`
  (results)

**Interfaces:**

- Consumes: ilmenite on the new layout (Task 6).
- Produces: the written results the spec's exit criteria require, and the
  decision whether Task 7a runs.

**When a test fails:** stop the sequence, record the observation in the
results table, and consult the spec's Risks section for the named fallback.
A fix is a commit on this branch, evaluated with the Task 2 or Task 3 gates,
then applied by the owner on ilmenite from their clone with
`sudo nixos-rebuild switch --flake .#ilmenite` (not `boot`: a kernel change
followed by a hibernate loses that session), after which the failed test is
re-run before the next one starts. The executor never runs the switch.

- [ ] **Step 1: The verification doc text (written in Task 6 step 1)**

````markdown
# ilmenite hibernation verification

**Status:** In progress
**Date:** <date of the install>
**Owner:** djacu
**Context:** Tasks 6 and 7 of `docs/plans/completed/ilmenite-hibernation-implementation.md`; design in `docs/plans/completed/ilmenite-hibernation.md`

## Install log

- Staged fingerprint: <fingerprint>; machine-id: <id>.
- Host-id pre-seed: both `od` lines `4d a7 66 11`.
- Install: started <time>, ended <time>; prompts at first boot: <n>, prompt
  named <cryptswap|cryptzroot>; anything odd in the disko or nixos-install
  output: <none|notes>.
- Post-install checks: <all passed | list>.
- `BAT1/alarm` at first boot: <value>. Greater than zero means systemd uses
  the firmware alarm path in suspend-then-hibernate.

## Tests

The owner runs the (ilmenite) commands in fish on the laptop; the executor
runs the (argentite) commands in bash over SSH, read-only. systemd-sleep's
path decisions are debug-level messages, so each session that includes
tests 3, 4, or 5 starts with the session setup below and ends with its
removal. The drop-ins live in `/run`: a resume keeps them, a cold boot
drops them, so repeat the setup after any reboot.

Session setup (ilmenite):

```fish
sudo mkdir -p /run/systemd/system/systemd-suspend-then-hibernate.service.d
printf '[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\n' | sudo tee /run/systemd/system/systemd-suspend-then-hibernate.service.d/debug.conf
sudo systemctl daemon-reload
```

Session teardown (ilmenite):

```fish
sudo rm -rf /run/systemd/system/systemd-suspend-then-hibernate.service.d /run/systemd/sleep.conf.d
sudo systemctl daemon-reload
```

### 1. Cold boot ordering

(ilmenite) Reboot, count prompts. Then:

```fish
journalctl -b -o short-monotonic -u systemd-cryptsetup@cryptswap.service -u systemd-cryptsetup@cryptzroot.service -u systemd-hibernate-resume.service -u zfs-import-zroot.service -u rollback-root.service --no-pager
journalctl -b -p warning --no-pager | grep -i 'ordering cycle'
```

Pass: one prompt; in the first listing `systemd-cryptsetup@cryptswap.service`
finishes before `systemd-hibernate-resume.service` starts (the resume unit
binds to the swap mapper, not the pool one, so `cryptzroot` may finish
later); the resume unit and `systemd-cryptsetup@cryptzroot.service` both
finish before `zfs-import-zroot.service` starts; the import finishes before
`rollback-root.service` starts. The second command prints nothing. (PID 1 logs
units by description, so the unit filters are what make the first command
show them.)

### 2. Hibernate and resume, cold ARC and warm ARC

(ilmenite) `/tmp` lives on the root dataset, which is rolled back on every
cold boot, so a marker there survives a resume and nothing else:

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

Pass: marker from before the hibernate, uptime continued, no ACPI errors,
S4 entry and wake lines present. Note whether `spd5118` still returns `-6`.

Warm ARC: the ARC cap at this pin is RAM minus 1 GiB, about 63 GiB. Write a
random file of 50 GB, read it twice, confirm the ARC holds most of it, then
hibernate again the same way. This pushes saveable memory well past the
kernel's half-of-RAM image limit, so the ARC shrinker must give memory back.

```fish
dd if=/dev/urandom of=/home/djacu/arcfill bs=1M count=50000 status=progress
cat /home/djacu/arcfill > /dev/null; cat /home/djacu/arcfill > /dev/null
grep -E '^(size|c_max) ' /proc/spl/kstat/zfs/arcstats
date -u > /tmp/hibtest-marker; systemctl hibernate
```

After the resume: marker present; `sudo dmesg | grep -i -E 'hibernation|Image'
| tail -n 12` shows the image page count and no "Image allocation" or "Not
enough" error. Then `rm /home/djacu/arcfill`.

### 3. suspend-then-hibernate with a short delay

(ilmenite) Session setup first. Then a runtime-only sleep override, no
rebuild:

```fish
sudo mkdir -p /run/systemd/sleep.conf.d
printf '[Sleep]\nHibernateDelaySec=2min\nSuspendEstimationSec=2min\nHibernateOnACPower=yes\n' | sudo tee /run/systemd/sleep.conf.d/test.conf
date -u > /tmp/hibtest-marker; systemctl suspend-then-hibernate
```

Expected: suspend; after about two minutes the machine wakes by itself and
powers off (hibernated). Power on, one prompt, session back. Then:

```fish
cat /tmp/hibtest-marker
journalctl -b -u systemd-suspend-then-hibernate.service --no-pager | grep -i -E 'alarm|APM Timer|wakeup|Timer fired|timeout|estimat|hibernat|suspend' | head -n 40
sudo rm /run/systemd/sleep.conf.d/test.conf
```

Pass: marker present; the debug log shows which path systemd took
(firmware alarm or timer) and, on the alarm path, "Woken by APM Timer"
rather than a silent exit after the wake. If the alarm path misjudged the
wake, which shows as the machine coming back awake after two minutes with
no hibernate and Plasma re-suspending it about ten seconds later, record
it and run Task 7a before test 4.

### 4. Lid on battery

(ilmenite, session setup active) Unplug.
`cat /sys/class/power_supply/BAT1/charge_now`, close the lid for ten
minutes, open it. Pass: `journalctl -b -u
systemd-suspend-then-hibernate.service --no-pager` shows one suspend entry
and no hibernate; `charge_now` dropped by about 0.1 %.

Overnight: `cat /sys/class/power_supply/BAT1/charge_now; date`, close the
lid unplugged, leave it. In the morning the machine is off. Power on, one
prompt, session back; `charge_now` again. Pass: the debug log shows the
hibernate about 3 h after the lid close, and the total drop is about 1.5 %
plus the hibernate.

### 5. Lid on AC, then unplug

(ilmenite, session setup active) Plugged in through the hub, no external
monitor. Close the lid for more than three hours, open it:

```fish
journalctl -b -u systemd-suspend-then-hibernate.service --since -5h --no-pager | grep -i -E 'suspend|wake|Timer fired|AC power|hibernat' | head -n 40
```

Pass: a wake about every three hours, each logged as the timer firing on
AC and followed by a new suspend, no hibernate. Then close the lid again,
unplug the hub after ten minutes, and leave it. Pass: within three hours
the machine is off; power on, one prompt, session back. Run the session
teardown afterwards.

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

(ilmenite) After any cold boot:

```fish
systemctl show -p Options -p ActiveState dev-mapper-cryptswap.swap
set dm (basename (readlink -f /dev/mapper/cryptswap)); cat /sys/block/$dm/queue/discard_granularity
```

Pass: `Options=defaults,discard=once` and `ActiveState=active` (Review Focus 7);
the granularity is greater than `0`, so the discard reaches the drive
through dm-crypt.

## Results

| Test | Date | Result | Notes |
| ---- | ---- | ------ | ----- |
|      |      |        |       |

## Decision

<Pass or fail against the spec's exit criteria, and anything changed as a result.>
````

- [ ] **Step 2: Run the tests (owner) and record (executor)**

Walk tests 1 to 8 with the owner, in the order written, with the session
setup and teardown where the doc says. For each, the executor fills the
results row. Tests 4 and 5 span many hours; the doc is committed with
`Status: In progress` between them.

- [ ] **Step 3: Commit after each session (bash)**

```bash
git add docs/investigations/ilmenite-hibernation-verification.md
git commit -m "docs/investigations: ilmenite hibernation verification: <tests done>

Assisted-by: Claude Code (claude-fable-5-1)"
```

When all eight have a result, set `Status: Complete`, write the Decision,
and commit with `<tests done>` = `complete`.

______________________________________________________________________

### Task 7a: Force the timer path (conditional)

Run only if test 3 showed the firmware alarm path misjudging the timed wake
(the machine came back awake after the delay and never hibernated). Skip
otherwise and note "not needed" in the verification doc's Decision.

**Files:**

- Modify: `nixos-configurations/ilmenite/hibernation.nix` (append)

**Interfaces:**

- Consumes: `hibernation.nix` (Task 3); the `BAT1/alarm` value from the
  install log.
- Produces: `BAT1/alarm` reading `0`, so systemd takes the timer path.

How it works, verified at the pin: systemd takes the alarm path only when
every battery's `alarm` attribute is greater than zero; the kernel's ACPI
battery driver exposes `alarm` read-write and evaluates the firmware trip
point `_BTP` with the written value, so `0` disables the trip point and the
attribute then reads `0`.

- [ ] **Step 1: Run the gate to see it fail (bash)**

```bash
nix eval --raw .#nixosConfigurations.ilmenite.config.services.udev.extraRules | grep -c 'ATTR{alarm}' || true
```

Expected: `0`.

- [ ] **Step 2: Append the rule to `hibernation.nix`**

Insert before the final `}`:

```nix

  # The firmware battery alarm path in suspend-then-hibernate judges a wake
  # by the SMBIOS wake-up byte, which this firmware misreports (verification
  # test 3). With the trip point disabled, systemd uses its own timer.
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", KERNEL=="BAT1", ATTR{alarm}="0"
  '';
```

Then `nix fmt -- nixos-configurations/ilmenite/hibernation.nix`.

- [ ] **Step 3: Run the gate to see it pass (bash)**

```bash
nix eval --raw .#nixosConfigurations.ilmenite.config.services.udev.extraRules | grep -c 'ATTR{alarm}' || true
nix build --no-link --print-out-paths .#nixosConfigurations.ilmenite.config.system.build.toplevel
```

Expected: `1`, then a store path.

- [ ] **Step 4: Commit and push (bash)**

```bash
git add nixos-configurations/ilmenite/hibernation.nix
git commit -m "nixosConfigurations.ilmenite: disable the battery trip point

systemd's suspend-then-hibernate judges a firmware-alarm wake by the
SMBIOS wake-up byte, which this firmware misreports, so timed wakes
were treated as manual and the machine never hibernated. With BAT1's
alarm at 0 systemd uses its own timer.

Assisted-by: Claude Code (claude-fable-5-1)"
git push
```

- [ ] **Step 5: Apply and re-test (owner, fish on ilmenite)**

```fish
git pull
sudo nixos-rebuild switch --flake .#ilmenite
sudo udevadm trigger --settle --subsystem-match=power_supply
cat /sys/class/power_supply/BAT1/alarm
```

Expected: `0`. Then re-run verification test 3; it must now take the timer
path and hibernate after the delay. Record both the failure and the fix in
the results table before moving to test 4.

______________________________________________________________________

### Task 8: Close out

**Files:**

- Move: `docs/plans/completed/ilmenite-hibernation.md` and
  `docs/plans/completed/ilmenite-hibernation-implementation.md` to
  `docs/plans/completed/`
- Modify: the spec's `**Status:**` line; path references in the files
  listed below

**Interfaces:**

- Consumes: a complete verification doc (Task 7).

- [ ] **Step 1: Move and mark (bash)**

Replace `<date>` with today's date before running.

```bash
git mv docs/plans/completed/ilmenite-hibernation.md docs/plans/completed/ilmenite-hibernation.md
git mv docs/plans/completed/ilmenite-hibernation-implementation.md docs/plans/completed/ilmenite-hibernation-implementation.md
sed -i 's|^\*\*Status:\*\* .*|**Status:** Completed <date>; verified on hardware, results in `docs/investigations/ilmenite-hibernation-verification.md`|' docs/plans/completed/ilmenite-hibernation.md
sed -i 's|docs/plans/completed/ilmenite-hibernation|docs/plans/completed/ilmenite-hibernation|g' docs/plans/completed/ilmenite-hibernation-implementation.md docs/investigations/ilmenite-hibernation-verification.md docs/plans/active/scheelite-force-import-root-decision.md docs/runbooks/install-laptop-with-nixos-anywhere.md nixos-configurations/ilmenite/hibernation.nix
nix fmt -- docs/plans/completed/ilmenite-hibernation.md docs/plans/completed/ilmenite-hibernation-implementation.md docs/investigations/ilmenite-hibernation-verification.md docs/plans/active/scheelite-force-import-root-decision.md docs/runbooks/install-laptop-with-nixos-anywhere.md nixos-configurations/ilmenite/hibernation.nix
grep -rn 'docs/plans/completed/ilmenite-hibernation' docs nixos-configurations; echo "<end>"
```

Expected: nothing before `<end>`. (The pattern carries the `docs/` prefix
so that this plan's own text, once moved, cannot match itself.)

- [ ] **Step 2: Commit (bash)**

```bash
git add docs/plans/completed/ilmenite-hibernation.md docs/plans/completed/ilmenite-hibernation-implementation.md docs/investigations/ilmenite-hibernation-verification.md docs/plans/active/scheelite-force-import-root-decision.md docs/runbooks/install-laptop-with-nixos-anywhere.md nixos-configurations/ilmenite/hibernation.nix
git commit -m "docs/plans: complete ilmenite hibernation

Assisted-by: Claude Code (claude-fable-5-1)"
git show --stat HEAD
```

Expected: the stat lists the two renames and the four edited files, nothing
else. The pre-existing `docs/plans/active/scheelite-remote-access.md`
intent-to-add entry stays out because the paths are explicit.

- [ ] **Step 3: Finish the branch**

Use superpowers:finishing-a-development-branch: the branch is already
pushed; open the PR against `main` with a body that lists the layout change,
the reinstall, the policy, Task 7a if it ran, and the verification doc,
ending with the single line `Assisted-by: Claude Code (claude-fable-5-1)`.
Update the memory file `project_ilmenite_hibernation_notes.md` and the
`MEMORY.md` index line to "done" with the date and the PR number.
