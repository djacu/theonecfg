# Scheelite ZFS hardening — postmortem (failed migration)

## TL;DR

Tried to migrate scheelite's ZFS datasets to `mountpoint=legacy` to
solve a dual-mount race between `zfs-mount.service` and
fstab-generated mount units, bundled with flipping
`boot.zfs.forceImportRoot=false` to follow upstream guidance. The
migration's next boot failed: disko's `options = ["zfsutil"]` in
`fileSystems` is incompatible with `mountpoint=legacy` (mount.zfs's
zfsutil mode refuses legacy datasets), so the stage-1 initrd mount of
`/sysroot/persist` failed and dropped the host into initrd emergency
mode. With `forceImportRoot=false`, there was no console recovery
path on NixOS's editor-disabled systemd-boot, requiring a rescue USB
to revert the live pool back to path mountpoints.

All commits associated with the migration were reverted on 2026-06-01.
The race remains unfixed; scheelite is back to its prior
recoverable-via-Ctrl-D state.

## Context

scheelite's first boot under nixpkgs 26.05 (during the input-upgrades
deploy on 2026-05-31) tripped emergency.target because `tank0.mount`
(and 27 sibling fstab-generated mount units) raced and lost against
`zfs-mount.service`'s `zfs mount -a`. The race was masked in earlier
systemd by an auto-emitted skip-if-already-mounted condition that
systemd 260.1's fstab-generator no longer produces.

The plan was to set `mountpoint=legacy` on every flippable dataset
across `scheelite-tank0` and `scheelite-root`. That would make
`zfs-mount.service` skip them (legacy datasets aren't auto-mounted),
leaving the fstab mount units as the sole mounters. The
`forceImportRoot` flip to `false` was bundled in to align with
upstream's new conservative default — separate goal, same deploy.

## The trap

disko's NixOS module generates this for every ZFS filesystem:

```nix
fileSystems."/path" = {
  device = "pool/dataset";
  fsType = "zfs";
  options = [ "zfsutil" ];
};
```

`mount.zfs` in zfsutil mode is mutually exclusive with legacy
datasets — it refuses them. So setting `mountpoint=legacy` on a
disko-managed dataset makes its fstab mount unit fail:

```
filesystem 'pool/dataset' cannot be mounted using 'zfs mount'.
Use 'zfs set mountpoint=/path' or 'mount -t zfs pool/dataset /path'.
```

For `/persist` (which has `neededForBoot = true`), this failure is
fatal: stage-1 initrd's `/sysroot/persist` mount can't complete, and
the host drops into initrd emergency mode with no usable shell (root
account locked, no shell available). The bundled
`forceImportRoot=false` change meant we couldn't even add
`zfs_force=1` at the bootloader, since NixOS disables systemd-boot's
editor by default (`boot.loader.systemd-boot.editor` defaults to
`false`).

The only recovery was a NixOS installer USB to reset the live pool
properties back to their original paths.

## Sequence of events (2026-05-31 → 2026-06-01)

- Deploy with disko legacy + `forceImportRoot=false` applied to
  scheelite via `nixos-rebuild switch`. Activated cleanly; host
  running.
- Phase 1 live migration executed: stop services, `zfs set
  mountpoint=legacy` on tank0 + most of root pool. `/persist` and
  `/home` flipped via `zfs set -u` because impermanence bind-mounts
  held them busy. Live state checked good.
- `systemctl reboot`.
- First boot drops to initrd emergency: `Failed to mount
  /sysroot/persist`. The error message is opaque from the console.
- Boot a previous generation (which had `forceImportRoot=true`):
  same failure. The boot failure is from the on-disk pool state, not
  from any generation's config.
- Boot NixOS installer USB. Force-import pool; reproduce the legacy
  mount failure manually (`mount -t zfs -o zfsutil
  scheelite-root/safe/persist /mnt/persist` → "filesystem cannot be
  mounted using 'zfs mount'"). Diagnosis confirmed.
- Revert live pool: walk every flipped dataset, `zfs set -u
  mountpoint=<original path>`. Export both pools cleanly; reboot.
- Host comes back up. `tank0.mount` trips emergency mode as
  before-the-deploy (the race we set out to fix), recoverable via
  Ctrl-D.

## Root causes

1. **disko + ZFS legacy + zfsutil incompatibility.** disko
   unconditionally emits `options = ["zfsutil"]` in every NixOS
   `fileSystems` entry it generates; `mount.zfs`'s zfsutil mode is
   incompatible with legacy datasets. Setting `mountpoint=legacy` on
   a disko-managed dataset silently creates a broken boot
   configuration with no warning at deploy time.

2. **Bundled flag flip removed the recovery escape.** Pinning
   `forceImportRoot=false` simultaneously with the (untested)
   migration meant the failed boot couldn't be force-imported past
   at the bootloader. Even if NixOS's systemd-boot editor were
   enabled, `zfs_force=1` wouldn't have fixed the actual problem
   (legacy vs zfsutil), but the bundled flip removed even the
   illusion of escape and made every generation's boot equally
   broken.

3. **No pre-deploy validation of the next-boot path.** The migration
   was verified to work on the running system (filesystems
   remounted, services restarted), but the *next boot* path through
   stage-1 initrd was never exercised before deploying to production.

## What we should have done

- Tested the disko legacy migration in `nixos-rebuild build-vm`
  with a matching simulated pool state, before live-deploying to
  scheelite. A test that exercises a full cold boot would have
  surfaced the zfsutil/legacy incompatibility immediately.
- Kept `forceImportRoot=true` until the migration was verified
  successful on at least one cold-boot. The flag flip is a
  separate goal with its own threat model — bundling them removed
  the only mechanism that lets a sloppy migration recover
  unattended.
- Searched upstream (disko issues, nixpkgs PRs) for any prior art
  on ZFS legacy mountpoint migrations under disko before assuming
  it was a simple property flip.

## What's deferred

- The original dual-mount race is unfixed. scheelite still boots
  into emergency mode occasionally and requires Ctrl-D to continue.
  A proper fix needs to either (a) override disko's zfsutil
  emission to allow a clean legacy migration, or (b) find some
  other way to make `zfs-mount.service` skip the conflicting
  datasets — possibly a unit-level override that adds
  `ConditionPathIsMountPoint=!<path>` back to the fstab-generated
  units, replicating the old systemd-fstab-generator behavior.
- `forceImportRoot=false` (upstream's recommended default) is still
  unfollowed. Revisit only *after* the boot reliability issue is
  resolved, and deploy as its own change with a clean
  unattended-recovery story.

## Reverts (2026-06-01)

| Commit | Subject |
|--------|---------|
| `<this set>` | `nixosConfigurations.scheelite: revert ZFS mountpoints from legacy back to paths` |
| `<this set>` | `nixosConfigurations.argentite: revert boot.zfs.forceImportRoot back to true` |
| `<this set>` | `nixosConfigurations.cassiterite: revert boot.zfs.forceImportRoot back to true` |
| `<this set>` | `nixosConfigurations.malachite: revert boot.zfs.forceImportRoot back to true` |
| `<this set>` | `nixosConfigurations.scheelite: revert boot.zfs.forceImportRoot back to true` |
| `<this set>` | `docs/plans: move scheelite-zfs-hardening to completed as postmortem` |

Live pool was reverted via rescue USB on the night of 2026-05-31; the
config reverts above bring the disko / per-host config back in sync
with that live state.
