# scheelite disk-path naming strategy

Investigation of how to name the disks in the two ZFS pools for `disko.nix`
and runtime ZFS imports, and why we chose what we chose. Captures findings
from a probe session on the live scheelite system on 2026-05-02.

## TL;DR

- **Current decision**: `/dev/disk/by-id/wwn-...` for **both pools** in
  disko.nix and at runtime via `boot.zfs.devNodes = "/dev/disk/by-id"`.
- **Cost**: when a tank0 disk fails, replacing it requires a one-line
  edit to `disko.nix` (swap the old WWN for the new one) so future
  `nixos-anywhere` reinstalls reproduce correctly.
- **Future option**: switch tank0 to `/dev/disk/by-vdev/` aliases (Path A
  below) once the homelab is running and verified, to remove the disko
  edit on disk replacement. We have a complete reference config for that
  migration.
- **What we tried but couldn't get working**: `vdev_id` with
  `topology sas_switch`. The script's port-walk logic doesn't match
  scheelite's specific expander sysfs layout. Cause not fully pinned
  down; alias mode sidesteps the issue entirely.

## Hardware survey — captured 2026-05-02

### NVMe boot mirror

| Slot | PCI BDF | Device | by-id | Serial |
|---|---|---|---|---|
| M.2_1 (CPU-direct) | `0000:01:00.0` | `nvme1n1` | `nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0X208893V` | …208893V |
| M.2_2 (chipset)    | `0000:10:00.0` | `nvme0n1` | `nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0X208806D` | …208806D |

Two NVMes on different PCIe complexes. by-path is stable; by-id is
canonical.

### Tank0 (HGST x8 raidz3)

- HBA at PCI `0000:08:00.0` (LSI SAS-class card).
- SAS expander on the SilverStone RM43-320-RS backplane at SAS address
  `0x50000d1701ffd63f`.
- 8 disks on expander phys 8–15, occupying SES bays 8–15.
- The expander reports a 24-slot map (`/sys/class/enclosure/0:0:8:0/`
  has `Array Device 00 ` … `Array Device 23 `) but the chassis only has
  20 physical bays — slots 16–23 are firmware padding.

| SES bay | sd* | WWN | expander phy | port (phy/4) |
|---|---|---|---|---|
| 8  | sda | `wwn-0x5000cca2902be164` | 8  | 2 |
| 9  | sdb | `wwn-0x5000cca2902c3b14` | 9  | 2 |
| 10 | sde | `wwn-0x5000cca2902c39f4` | 10 | 2 |
| 11 | sdd | `wwn-0x5000cca2902c71c8` | 11 | 2 |
| 12 | sdc | `wwn-0x5000cca2902c3a78` | 12 | 3 |
| 13 | sdf | `wwn-0x5000cca2902bcf64` | 13 | 3 |
| 14 | sdg | `wwn-0x5000cca2902c6ed0` | 14 | 3 |
| 15 | sdh | `wwn-0x5000cca2902b7288` | 15 | 3 |

Phys 8–11 → port 2 (one SFF-8643 cable, 4 disks).
Phys 12–15 → port 3 (other SFF-8643 cable, 4 disks).
SES `bay_identifier` matches expander phy number 1:1.

### Sysfs path the kernel uses for an HGST (sda example)

```
/sys/devices/pci0000:00/0000:00:02.1/0000:02:00.0/0000:03:08.0/
  0000:06:00.0/0000:07:00.0/0000:08:00.0/host0/port-0:0/
  expander-0:0/port-0:0:0/end_device-0:0:0/
  target0:0:0/0:0:0:0/block/sda
```

`phy_identifier` and `bay_identifier` (both = 8 for sda) are at:

```
.../end_device-0:0:0/sas_device/end_device-0:0:0/{phy,bay}_identifier
```

## Path comparison

| | by-id | by-path | by-vdev (sas_switch) | by-vdev (alias) |
|---|---|---|---|---|
| Source of names | disk serial / WWN | bus topology | computed from sysfs phy + SES bay | hardcoded in `vdev_id.conf` |
| Stable when disk replaced in same bay? | **No** (new WWN) | Yes | Yes | Yes |
| Stable when HBA moves PCIe slot? | Yes | No | Yes (port-anchored) | No (BDF in alias) |
| Stable when BIOS renumbers BDF? | Yes | No | Yes (port-anchored) | No |
| Friendly names in `zpool status`? | No (long WWN) | No (long path) | Yes (`A8`–`B15`) | Yes (whatever you choose) |
| Works on scheelite hardware? | Yes (verified) | Yes (verified) | **No** (script port-walk mismatch) | Likely yes (not yet tested) |
| Lines of config | None | None | ~7 lines | 8 lines (one per disk) |
| `disko.nix` edit on disk replacement? | **Yes** | No | No | No |

## Why sas_switch didn't work on this hardware

### What we observed

After authoring the obvious config:

```
multipath           no
topology            sas_switch
phys_per_port       4
slot                bay
channel 2 A
channel 3 B
```

and triggering udev, no `/dev/disk/by-vdev/` symlinks appeared. Tracing
`vdev_id -d sda` with `sh -x` showed:

- The script's port-walk loop ran with `j=13` (not `i+4=14` as
  `sas_switch` should produce, nor `i+1=11` as `sas_direct` would).
- Result: `port_dir` ended up at `…/end_device-0:0:0/`, one level too
  deep.
- `ls -vd "$port_dir"/phy*` returned empty (phy* glob doesn't match
  anything in `end_device-0:0:0/` directly — `phy_identifier` is in
  `…/sas_device/end_device-…/` instead).
- `PHY=0` → `PORT=0` → channel lookup found no match for port 0 (we
  defined channels 2 and 3 only).
- `ID_VDEV` empty → no symlink created.

### Hypotheses (not confirmed)

1. **TOPOLOGY isn't being read**. If `awk '$1 == "topology" {print $2}'`
   returns empty (e.g., due to invisible whitespace or a parse quirk),
   the case statement in `sas_handler()` falls through, leaving `j` at
   whatever residual value it had, which happened to be 13 in our trace.
   *Next debug step if revisited*:
   `awk '$1 == "topology" { print "[" $2 "]"; exit }' /etc/zfs/vdev_id.conf`
2. **`sas_switch` mode genuinely doesn't fit this layout**. The OpenZFS
   script's `sas_switch` mode walks `i+4` levels below `host*`, expecting
   the `phy*` symlinks to be siblings of `end_device-…`. On scheelite,
   `phy*` symlinks are siblings of `end_device-0:0:0` at the
   `port-0:0:0/` level (i+3), not at i+4. If that's the case, no built-in
   topology mode matches and we'd need a script patch or alias mode.

We didn't pursue the trace far enough to distinguish (1) from (2).

### Things we did verify directly

- The vdev_id udev rule (`69-vdev.rules`) is installed and active on
  scheelite via `pkgs.zfs`'s `services.udev.packages` registration.
- The vdev_id script lives at
  `/nix/store/<hash>-zfs-user-2.3.3/lib/udev/vdev_id` and is invoked by
  the rule on every block device add/change.
- `bay_identifier` and `phy_identifier` files exist and are readable
  in `/sys/.../sas_device/end_device-…/` (both = 8 for sda — confirms
  SES support is present and bay numbers are clean).
- `boot.zfs.pools.<name>.devNodes` exists in current nixpkgs at
  `nixos/modules/tasks/filesystems/zfs.nix:412–429` and is consumed by
  `poolImport` at line 86–87.
- Disko passes the `device` string verbatim into `zpool create` (no
  canonicalization), so any path that resolves at script-execution time
  is accepted.
- vdev_id's *script-execution* uses `/etc/zfs/vdev_id.conf` (`CONFIG`
  variable in the script) — `environment.etc."zfs/vdev_id.conf".text`
  in NixOS produces the right symlink for it.

## Path A — by-vdev alias mode (revisit option)

The reference configuration to try after the homelab is running and we
have a known-good baseline. Goal: keep all the swap-in-bay benefits of
by-vdev without depending on the topology mode that didn't work.

### `vdev_id.conf` (verified-correct paths from 2026-05-02 probe)

```
alias A8  /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy8-lun-0
alias A9  /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy9-lun-0
alias A10 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy10-lun-0
alias A11 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy11-lun-0
alias B12 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy12-lun-0
alias B13 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy13-lun-0
alias B14 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy14-lun-0
alias B15 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy15-lun-0
```

Each line maps a friendly name (`A8`, `B12`, etc.) to the kernel-derived
by-path string for that physical bay. Bay numbering preserved — `A10`
means port 2, bay 10. A new disk in bay 10 still lands at the same
by-path → still gets named `A10`.

### NixOS wiring

Add to `nixos-configurations/scheelite/default.nix`:

```nix
environment.etc."zfs/vdev_id.conf".text = ''
  alias A8  /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy8-lun-0
  alias A9  /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy9-lun-0
  alias A10 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy10-lun-0
  alias A11 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy11-lun-0
  alias B12 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy12-lun-0
  alias B13 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy13-lun-0
  alias B14 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy14-lun-0
  alias B15 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy15-lun-0
'';

# Per-pool override; root pool stays on the global by-id default.
boot.zfs.pools."scheelite-tank0".devNodes = "/dev/disk/by-vdev";
```

`disko.nix` stays on by-id — vdev_id rules don't run during the
nixos-anywhere installer environment, so disko has to use a path type
that's auto-populated. The runtime import uses by-vdev via the
per-pool override. ZFS reads its own labels off the disks at import
time; the path is purely "where to look," not "which disks."

### Non-destructive test before committing

Before switching the running system or doing anything destructive:

```fish
# Write the config to /etc/zfs (will be overwritten on switch but that's fine)
echo 'alias A8  /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy8-lun-0
alias A9  /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy9-lun-0
alias A10 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy10-lun-0
alias A11 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy11-lun-0
alias B12 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy12-lun-0
alias B13 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy13-lun-0
alias B14 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy14-lun-0
alias B15 /dev/disk/by-path/pci-0000:08:00.0-sas-exp0x50000d1701ffd63f-phy15-lun-0' \
  | sudo tee /etc/zfs/vdev_id.conf

sudo udevadm trigger --action=change --subsystem-match=block
sudo udevadm settle
ls -l /dev/disk/by-vdev/
```

Expect: 8 symlinks `A8 A9 A10 A11 B12 B13 B14 B15` pointing at
`/dev/sd*`. If correct, switch the Nix config in. If wrong (e.g., script
also fumbles alias mode), debug or fall back to Path B.

### Verification after switching to Path A

```sh
# Pool imports through by-vdev now
zpool status -P scheelite-tank0    # should show /dev/disk/by-vdev/A8 etc.

# Confirm symlinks live across reboots
sudo reboot
# after reboot:
ls -l /dev/disk/by-vdev/
zpool status -P scheelite-tank0
```

### Rollback to Path B if Path A breaks

```nix
# Remove these two stanzas from scheelite/default.nix
# environment.etc."zfs/vdev_id.conf" ...
# boot.zfs.pools."scheelite-tank0".devNodes ...
```

Then `nixos-rebuild switch`. ZFS will re-import via by-id on next boot
(or `zpool export/import -d /dev/disk/by-id`). No data risk because pool
labels are independent of import path.

## Path B — by-id everywhere (current configuration)

What's actually deployed in `disko.nix` today: each disk is identified
by its WWN under `/dev/disk/by-id/`. The `boot.zfs.devNodes` default of
`/dev/disk/by-id` covers the import path for both pools, no per-pool
override needed.

### Disk replacement procedure under Path B

1. ZFS marks the failed disk. `zpool status` shows the missing/faulted
   vdev with the old WWN.
2. Physically replace the disk in the same bay.
3. Get the new WWN: `ls /dev/disk/by-id/wwn-* | grep -v -- -part`
   (find the one not yet known to the pool).
4. `zpool replace scheelite-tank0 wwn-0x<old> /dev/disk/by-id/wwn-0x<new>`.
5. Wait for resilver.
6. Edit `nixos-configurations/scheelite/disko.nix` — change the
   matching `tank0_dN.device` from the old WWN to the new one.
7. Commit.

The `nixos-rebuild switch` after the disko edit is a no-op for the
running pool (disko only acts during install). The edit matters for
*future* `nixos-anywhere` reinstalls — without it, disko would build
the install with the now-missing old WWN and fail.

### Why this is acceptable

- HGST disks have multi-year MTBF; replacement events are rare.
- The disko edit is one line, low risk.
- No new failure modes from custom udev / vdev_id / per-pool overrides.

## Cross-cutting facts (apply regardless of path)

- The on-disk pool data is independent of the path strategy. Switching
  between paths never requires data migration; the pool is identified by
  its labels on the disks themselves.
- `zpool import -d <dir>` only tells ZFS which directory of symlinks to
  scan. It can be re-run with a different `-d` at any time.
- nixos-anywhere's installer environment doesn't load
  `/etc/zfs/vdev_id.conf` from the target system, so install-time disko
  configs must reference paths that udev populates automatically (by-id
  or by-path). by-vdev only works after first boot of the new system.
- The boot pool (`scheelite-root`) needs its import path to work in
  initrd, before stage-2 udev rules have fully fired. by-id is the
  conservative default. There's no compelling reason to change the boot
  pool's strategy.

## Outstanding things to revisit if Path A is attempted later

- Whether `sas_switch` mode can be made to work with a config tweak
  (likely not, based on the trace — the script's hardcoded `i+4`
  doesn't match this expander layout). Not worth the time.
- Whether `enclosure_symlinks yes` plus `slot ses` could give us a
  better answer (haven't explored).
- Whether OpenZFS upstream would accept a topology mode for
  3-level-deep expander layouts.

## Source files referenced

- OpenZFS vdev_id script: `udev/vdev_id` in the openzfs/zfs source.
- Topology examples:
  - `etc/zfs/vdev_id.conf.sas_direct.example`
  - `etc/zfs/vdev_id.conf.sas_switch.example`
  - `etc/zfs/vdev_id.conf.alias.example`
- nixpkgs ZFS module: `nixos/modules/tasks/filesystems/zfs.nix`
  (lines 86–87 for per-pool import, 412–429 for the per-pool option).
- disko: `lib/types/disk.nix`, `lib/types/zfs.nix`, `lib/types/zpool.nix`.
- This repo: `nixos-configurations/scheelite/disko.nix` (current by-id
  config), `nixos-configurations/scheelite/default.nix` (current
  `boot.zfs.devNodes` setting).
