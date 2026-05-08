# Why NVMe SMART metrics are blocked on a fresh deploy

**Context:** scheelite, 2026-05-07. After enabling
`theonecfg.services.monitoring.smartctl-exporter`, SAS drives showed up in
Prometheus immediately, NVMe drives didn't — exporter logged
`Permission denied` on `/dev/nvme0` and `/dev/nvme1` until
`udevadm trigger --action=add --subsystem-match=nvme` was run once.
This explains why.

## 1. Block vs character devices in `/dev`

Linux exposes hardware devices through two flavors of device file:

- **Block devices** (`b` in `ls -l`) handle data in fixed-size buffered
  chunks. Filesystems sit on top of them. `/dev/sda`, `/dev/nvme0n1`,
  `/dev/dm-0` — all block.
- **Character devices** (`c` in `ls -l`) are unbuffered, byte-stream
  (or ioctl-driven) interfaces. `/dev/tty*`, `/dev/kvm`, and the NVMe
  *controller* nodes `/dev/nvme0`, `/dev/nvme1`.

The NVMe driver intentionally splits these:

- `/dev/nvme0` — the **controller character device**. ioctl interface
  for admin commands: identify, get-log-page, firmware download/commit,
  namespace create/delete, security send. This is what `smartctl` opens
  to read SMART/health information via the NVMe Admin Command set
  (`Get Log Page` opcode `02h`).
- `/dev/nvme0n1` — the **namespace block device**. Bytes you'd put a
  filesystem on. Has a partition table, gets `/dev/nvme0n1p1` etc.

`smartctl -a /dev/nvme0` works because the controller node is where the
admin-command transport lives. SAS/SATA disks don't have this split —
`/dev/sda` is one block device that handles both data I/O and SCSI
passthrough (`SG_IO`) for SMART.

## 2. udev decides who owns `/dev/*`

The kernel doesn't set ownership or mode on device nodes — it just
emits a uevent saying "I created this." The userspace daemon
**systemd-udevd** watches that netlink socket and applies rules from
`/etc/udev/rules.d`, `/run/udev/rules.d`, and `/usr/lib/udev/rules.d`.

The default rule for block devices ships in systemd's
`rules.d/50-udev-default.rules.in`:

```
SUBSYSTEM=="block", GROUP="disk"
```

That's why `/dev/sda` shows up as `0660 root:disk` and `/dev/nvme0n1`
(also block subsystem) inherits the same. There is **no** corresponding
`SUBSYSTEM=="nvme", GROUP="..."` line in upstream systemd, so the
controller char node falls through to the default `0600 root:root`.

That gap is tracked in
[systemd/systemd#26009](https://github.com/systemd/systemd/issues/26009);
discussion stalled on which group the controller should belong to —
a security policy decision, not a clear default.

## 3. Two ways to grant access: traditional groups vs POSIX ACLs

**Traditional approach.** Change the group of the device file and add
the service user to that group:

```
chgrp disk /dev/nvme0
usermod -aG disk smartctl-exporter
```

Works, but coarse. `disk` membership now grants the service rw on
every block device in the system *and* on the NVMe controller.
Combined with the exporter's `CAP_SYS_ADMIN`, any compromise of the
exporter — or any other process that already runs as `disk` — could
send `nvme-cli format`, `nvme firmware-download`, `nvme delete-ns`.
That's why
[NixOS/nixpkgs#205165](https://github.com/NixOS/nixpkgs/pull/205165),
which proposed `GROUP="disk"` for NVMe, was rejected.

**POSIX ACL approach.** Layer per-principal access control entries on
top of the existing owner/group/other bits without changing them:

```
setfacl -m g:smartctl-exporter-access:rw /dev/nvme0
```

Now `getfacl /dev/nvme0` shows an extra
`group:smartctl-exporter-access:rw-` entry. The file is still
`0600 root:root` for everyone else; only members of
`smartctl-exporter-access` get the extra rights. ACLs require kernel
support (`CONFIG_FS_POSIX_ACL`, on by default) and a filesystem that
stores them — `devtmpfs` does.

NixOS chose the ACL path in
[NixOS/nixpkgs#333961](https://github.com/NixOS/nixpkgs/pull/333961).
The rule installed by the exporter module is roughly:

```
ACTION=="add", SUBSYSTEM=="nvme", KERNEL=="nvme[0-9]*", \
  RUN+="${pkgs.acl}/bin/setfacl -m g:smartctl-exporter-access:rw /dev/%k"
```

A dedicated group `smartctl-exporter-access` is created so the policy
is scoped to "things explicitly opted into NVMe SMART access" — not
all of `disk`.

## 4. The systemd-side gates on the unit

Filesystem permission is one layer. The unit's hardening adds two more:

- `DynamicUser=true` — systemd allocates an ephemeral UID/GID at start,
  releases at stop. The user `smartctl-exporter` doesn't persist in
  `/etc/passwd`.
- `SupplementaryGroups=disk smartctl-exporter-access` — adds these to
  the dynamic user's group list at process start. This is *how* the
  ACL above actually grants access: the running process must be a
  member of `smartctl-exporter-access` for the ACE to match.
- `AmbientCapabilities=CAP_SYS_RAWIO CAP_SYS_ADMIN` — capabilities the
  process inherits. NVMe admin ioctls (`NVME_IOCTL_ADMIN_CMD`) check
  `capable(CAP_SYS_ADMIN)`; SCSI passthrough (`SG_IO`) checks
  `CAP_SYS_RAWIO`. Without these, even root-equivalent file access
  wouldn't get past the ioctl handler.
- `DeviceAllow=block-blkext rw / block-sd rw / char-nvme rw` plus
  `DevicePolicy=closed` — the **cgroup device controller**, a
  kernel-level allowlist enforced before VFS even gets involved. With
  `DevicePolicy=closed`, only the listed device types/majors are
  reachable; everything else returns `EPERM` regardless of file mode.

These layers compose with AND semantics. Even if the ACL grants you
rw, `DevicePolicy=closed` without `char-nvme` blocks the open.
Conversely, `DeviceAllow` doesn't override DAC — `0600 root:root` with
no ACL still blocks a non-root, non-capable user. **Every gate must
permit.**

## 5. The full chain for a successful `smartctl -a /dev/nvme0`

1. Kernel emits `add` uevent for `nvme0` → udev applies
   `ACTION=="add", SUBSYSTEM=="nvme"` rule → `setfacl` adds
   `g:smartctl-exporter-access:rw` to `/dev/nvme0`.
2. systemd-udevd reports the device exists; systemd's cgroup BPF filter
   for the unit allows `char-nvme rw` (configured at unit start).
3. `smartctl-exporter` opens `/dev/nvme0`. DAC check: ACL matches
   because the dynamic user is in `smartctl-exporter-access` → pass.
   Cgroup check: `char-nvme` allowed → pass.
4. Process issues `ioctl(fd, NVME_IOCTL_ADMIN_CMD, ...)` for
   `Get Log Page`. Kernel checks `CAP_SYS_ADMIN` → present in ambient
   set → pass. Drive returns the SMART/health log page.

## 6. Why the rule didn't take effect after deploy

`ACTION=="add"` matches **only** the kernel's initial device-add event,
fired when the NVMe driver binds to the PCIe device. After that, the
device just sits there; subsequent uevents on it are `change` (e.g.
when `udevadm control --reload` reapplies state) or `remove`.

When you `nixos-rebuild switch`, the activation script reloads udev
(`udevadm control --reload-rules && udevadm trigger`). But
`udevadm trigger` defaults to `--action=change`, and **`change` events
do not match `ACTION=="add"` rules**. So a new rule is loaded into the
daemon but has nothing to fire against until either:

- a real `add` happens (driver rebind, hotplug, or reboot), or
- you synthesize one:

```
sudo udevadm trigger --action=add --subsystem-match=nvme
```

After that, `getfacl /dev/nvme0` shows the `smartctl-exporter-access`
ACE. On the next reboot the kernel does a real bind and the rule fires
naturally — so this is a one-time post-deploy hiccup, not a permanent
issue.

A more robust rule could match `ACTION=="add|change"` so
reload-triggers work too. Whether nixpkgs wants that is a judgment
call (running `setfacl` on every change event is mostly harmless but
slightly noisy).

## Sources

- [systemd/systemd#26009](https://github.com/systemd/systemd/issues/26009)
  — NVMe devices have inconsistent permissions
- [NixOS/nixpkgs#333961](https://github.com/NixOS/nixpkgs/pull/333961)
  — fix that introduced the setfacl rule for smartctl_exporter
- [NixOS/nixpkgs#205165](https://github.com/NixOS/nixpkgs/pull/205165)
  — earlier attempt using `GROUP="disk"`, rejected
- [NixOS/nixpkgs#210041](https://github.com/NixOS/nixpkgs/issues/210041)
  — original "smartctl_exporter ignores nvme devices"
- `nixos/modules/services/monitoring/prometheus/exporters/smartctl.nix`
  in nixpkgs — where the udev rule and unit hardening live
