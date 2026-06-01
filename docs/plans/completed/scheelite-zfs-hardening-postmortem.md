# scheelite ZFS hardening — postmortem

## TL;DR

scheelite's first boot under nixpkgs 26.05 tripped emergency.target
because `tank0.mount` and its 27 sibling fstab-generated mount
units raced against `zfs-mount.service`'s `zfs mount -a` and lost.
The fix was to set `mountpoint=legacy` on every flippable dataset —
the standard NixOS+ZFS pattern that makes `zfs-mount.service` skip
the datasets entirely, leaving fstab units as the sole mounter.

A first attempt at the migration on 2026-05-31 bricked the host
and required a rescue USB to recover. Initial diagnosis blamed the
migration approach itself (claimed disko + mountpoint=legacy +
zfsutil was incompatible); that diagnosis was wrong. The actual
root cause was a combination of bundling `forceImportRoot=false`
with the migration (removed the unattended-recovery escape hatch)
and an activation cascade that left the pool in an unclean state,
exacerbated by attempts to fall back to older generations that had
different fstab content from the migrated live pool.

A second attempt on 2026-06-01 with the corrected understanding
and a more careful execution succeeded. Three consecutive clean
reboots confirmed the race is structurally fixed.

## Original symptom

After the 2026-05-31 input-upgrades deploy, scheelite reboots
landed in emergency mode because `tank0.mount` failed with:

```
zfs-import-scheelite-tank0.service: Successfully imported scheelite-tank0
tank0.mount: Directory /tank0 to mount over is not empty, mounting anyway.
mount[…]: zfs_mount_at() failed: mountpoint or dataset is busy
Failed to mount /tank0. → emergency.target trips
```

The pool imported cleanly; only the systemd-generated mount unit
failed. The host could be recovered by pressing Ctrl-D out of
emergency mode, but every boot would trip again.

## Root cause of the race

systemd-fstab-generator (the systemd unit responsible for
producing `.mount` units from `/etc/fstab`) used to emit a
skip-if-already-mounted condition on its generated units —
historically this happened. systemd 260.1 (shipped with nixpkgs
26.05) no longer emits any such condition. The journal on this
host shows the older condition behavior on May 3 and May 6 boots
(`Condition check resulted in /tank0 being skipped`), then the
race-and-fail behavior under 26.05.

The race itself is between:
- `zfs-mount.service` (After=zfs-import.target, Before=local-fs.target):
  runs `zfs mount -a` which mounts all non-legacy datasets via
  `zfs mount`.
- Each fstab-generated `.mount` unit (e.g. `tank0.mount`): runs
  `mount -t zfs -o zfsutil <dataset> <path>` via `mount.zfs`.

`zfs mount` is idempotent on already-mounted targets. `mount.zfs`
called from systemd is not — it returns `EBUSY`. For tank0,
where the import service runs in main systemd and both mounters
become eligible at the same target completion, the race resolves
unfavorably and the unit fails fatally.

The root pool's datasets have the same dual-mount setup but
their import happens in stage-1 initrd, so by the time
zfs-mount.service runs in stage 2, the fstab units have had
plenty of head-start. The race resolves favorably for root-pool
mounts in practice.

## The fix: `mountpoint=legacy`

Setting `mountpoint=legacy` on a dataset:
- Tells `zfs mount -a` to skip it (legacy = user-managed).
- Tells disko to omit `zfsutil` from the corresponding
  `fileSystems.<path>.options` (verified at
  `disko/lib/types/zfs_fs.nix:177`).
- Lets `mount.zfs` in plain mode (no zfsutil) mount the dataset
  via fstab.

End result: only one mounter, no race.

## What went wrong on 2026-05-31

The first attempt was technically correct in approach but bundled
several risk-amplifying changes in one deploy:

1. **Migration was bundled with `forceImportRoot=false`.** The
   stated goal was to align with upstream's new conservative
   default. The actual effect was to remove the
   force-import-past-an-unclean-pool recovery path.

2. **The activation cascade during `nixos-rebuild switch` itself
   tripped emergency mode** before the live property migration ran.
   The race was active during the unit-reload cascade. The host had
   to be recovered via Ctrl-D, then live migration completed in a
   limp-along state, then the reboot was attempted from an unclean
   pool.

3. **The unclean pool state, combined with `forceImportRoot=false`,
   prevented the new generation from importing.** The error
   manifested as "Failed to mount /sysroot" but the underlying
   issue was the pool refusing to import without `-f`.

4. **The operator fell back to a previous generation** whose disko
   config still had path mountpoints. That generation's fstab had
   `zfsutil` for every dataset. Live pool had been flipped to
   legacy. mount.zfs zfsutil-mode + legacy = mount refused. The
   `Failed to mount /sysroot/persist` error in this case really was
   the zfsutil/legacy incompatibility — but only because the
   operator was running an *older* config than the live pool state.

5. **Rescue USB rollback** worked: reverted the live pool back to
   path mountpoints, brought the host back up.

The initial postmortem misread step 4's manual reproduction
(`mount -t zfs -o zfsutil ... legacy` failing) as a general
incompatibility. It's actually only a problem when the fstab in
question was generated *before* the live pool was flipped to
legacy. In the proper end-state (disko + live pool both legacy),
disko correctly omits zfsutil and the migration works.

## The retry: 2026-06-01

The retry plan (`docs/plans/completed/scheelite-zfs-legacy-retry.md`)
addressed every finding from an adversarial review:

- Pre-deploy `nix eval` gate on `fileSystems.<path>.options`
  confirmed disko was producing the expected output (no zfsutil
  on flipped datasets, zfsutil retained on `/` and `/nix`).
- Excluded `/` and `/nix` from the flip — they can't be
  unmounted from a running system, and the resulting
  partial-migration state would have created the same fstab/live
  mismatch that broke yesterday's previous-generation boot.
- Used `nixos-rebuild boot` instead of `switch`, deferring
  activation to the next reboot. This avoided the activation
  cascade that tripped emergency mode last time.
- Kept `forceImportRoot=true` throughout, preserving the
  recovery escape hatch.
- Accepted `zfs set -u` (set-without-unmount) for `/persist` and
  `/home` as the correct tool — not a band-aid — for paths that
  can't be live-unmounted (impermanence bind-mounts hold
  `/var/log`, `/etc/machine-id`, etc.).
- Pruned older generations via `nix-collect-garbage` to reduce
  the surface area of "wrong generation to boot if migration
  fails."
- Documented the rescue-USB rollback procedure inline so a
  stressed operator wouldn't have to piece it together.

Outcome: deploy succeeded, live migration completed without
incident, three consecutive reboots came up clean.

## What stays deferred

- **`local/root` (`/`) and `local/nix` (`/nix`)** still have path
  mountpoints. Their race is theoretical (resolves favorably in
  practice due to stage-1 initrd timing), but they should be
  migrated to legacy via a rescue-USB maintenance event for
  consistency.
- **`boot.zfs.forceImportRoot = false`** (upstream's
  conservative default) is still unfollowed. Worth revisiting,
  but only as its own change after the migration has had time to
  bake.
- **The "directory not empty" warning** still appears in
  `tank0.mount`'s journal:
  `tank0.mount: Directory /tank0 to mount over is not empty,
  mounting anyway.`
  The mount succeeds. The cause is that child mountpoint
  directories get created (probably by tmpfiles or by the act of
  generating the .mount units' directories) before `tank0.mount`
  fires. Cosmetic only; doesn't cause failure.

## Lessons

1. **Don't bundle ZFS pool property changes with
   forceImport flag changes.** A failed migration with
   `forceImportRoot=false` and no editor-enabled bootloader is
   genuinely unrecoverable without external media.
2. **Don't fall back to older generations after a live pool
   property migration.** Older generations have a different
   fstab and will fail the boot with a misleading-looking error.
3. **Verify rendered config before deploying.** `nix eval` on
   `fileSystems.<path>.options` is cheap, easy, and would have
   surfaced any disko-behavior surprises before they could brick
   the host.
4. **`nixos-rebuild boot` is safer than `switch` when the deploy
   involves live state changes** that need to happen between
   config and activation. Defer activation to the next boot;
   give yourself time to put the live state right first.
5. **`zfs set -u` is a first-class tool for paths that can't be
   unmounted live**, not a workaround. Use it when impermanence
   bind-mounts or active sessions hold paths open.
6. **An adversarial review of a "retry" plan saves real
   downtime.** The first draft of the retry plan inherited
   several quiet assumptions from the original failed attempt
   (band-aids unnecessary, /and /nix could be flipped, etc.) —
   external review caught all of them.

## Reference timeline

- 2026-05-31 evening: First migration attempt. Activation
  cascade trips emergency mode. Live migration completed in
  limp-along state. Reboot fails because of
  forceImportRoot=false + unclean pool. Rescue USB to revert
  live pool. Host back up but on a pre-migration generation, in
  the original racey state.
- 2026-06-01 morning: Reverted the broken commits. Initial
  postmortem published (this file's prior contents)
  misdiagnosing the failure.
- 2026-06-01 afternoon: User pushed back on the misdiagnosis.
  Investigation revealed disko correctly handles legacy
  mountpoints. Adversarial review of a retry plan caught
  several inherited bad assumptions. Retry plan rewritten.
- 2026-06-01 late afternoon: Retry executed. Clean migration,
  3 clean reboots, race structurally fixed.
