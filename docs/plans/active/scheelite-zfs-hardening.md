# Scheelite ZFS hardening: legacy mountpoints + forceImportRoot to upstream default

## Context

Two coordinated changes to fix one acute bug and align scheelite (and the
other hosts) with upstream ZFS guidance.

### Bug: tank0 dual-mount race on boot

After the input-upgrades deploy, rebooting scheelite drops into emergency
mode. The pool imports cleanly; `tank0.mount` fails:

```
zfs-import-scheelite-tank0.service: Successfully imported scheelite-tank0
tank0.mount: Directory /tank0 to mount over is not empty, mounting anyway.
mount[…]: zfs_mount_at() failed: mountpoint or dataset is busy
Failed to mount /tank0. → emergency.target trips
```

### Root cause: zfs-mount.service vs fstab-generated mount units

scheelite's disko config (`nixos-configurations/scheelite/disko.nix`)
sets two things on every non-`canmount=off` dataset:

1. `options.mountpoint = "/path";` — the ZFS dataset property.
2. `mountpoint = "/path";` — disko's top-level option, emits a NixOS
   `fileSystems."/path"` entry which systemd-fstab-generator turns into
   a `.mount` unit.

Both pool imports use `zpool import -N` (no auto-mount on import) —
verified at `importLib.poolImport` in `<nixpkgs>/nixos/modules/tasks/filesystems/zfs.nix:79-117`.
The auto-mount that races the systemd unit is from `zfs-mount.service`
(zfs unit at `<store>/zfs-user-2.2.6/etc/systemd/system/zfs-mount.service`):

```
After=zfs-import.target
Before=local-fs.target
ExecStart=/.../zfs mount -a
```

`zfs mount -a` mounts every non-legacy dataset. `zfs mount` is idempotent
on already-mounted targets; `mount -t zfs` (from the systemd unit) is
NOT — it returns `EBUSY`. So for tank0, where the import service runs in
main systemd and the race against `zfs-mount.service` is tight, `zfs mount -a`
wins and the later `tank0.mount` (and 27 siblings) trip emergency.target.

Prior nixpkgs versions papered over this with a skip-condition on
auto-generated mount units (visible in journal: `Condition check resulted
in /tank0 being skipped` on May 3 and May 6 boots). The current systemd
(260.1, `src/fstab-generator/fstab-generator.c`) no longer emits any
such condition.

### Why scheelite-root isn't tripping today (yet)

Same dual-mount config, same latent risk. But the root pool is imported
in stage-1 initrd, so by the time main systemd starts, the pool has
been imported for many seconds. `nix.mount`, `home.mount`,
`persist.mount`, and the postgres mount units fire from fstab as soon
as systemd reads it — much earlier than `zfs-mount.service`, which
waits on `zfs-import.target` (delayed until tank0 finishes its 5+
second raidz3 import). Root-pool fstab units consistently win their
race; tank0's race tightly and lose.

`/` itself has no race at all: it's mounted in initrd before main
systemd starts. By the time `zfs-mount.service` runs, `zfs mount` finds
the dataset already mounted at `/` and silently no-ops.

### Why upstream recommends `boot.zfs.forceImportRoot = false`

The current option doc (`<nixpkgs>/nixos/modules/tasks/filesystems/zfs.nix:355-377`):

> It is highly recommended to keep this option disabled as it bypasses
> ZFS safeguard that protect your pools.

`-f` on `zpool import` specifically bypasses:

- **hostid mismatch refusal.** ZFS stamps a pool with the importing
  host's hostid. A different hostid → refuses without `-f`. This
  prevents accidental cross-host imports (drive moved between
  machines, restored to wrong host, etc.).
- **"in use by another system" refusal.** Same metadata path. If the
  pool wasn't cleanly exported, ZFS marks it in-use. Without `-f`, the
  next host (even the same one!) refuses. This prevents
  concurrent-import scenarios.

The catastrophic failure mode these safeguards prevent: two hosts
mounting the same pool simultaneously → independent uberblock chains
ratchet → silent on-disk corruption with no recovery.

For scheelite: dedicated internal storage, stable deterministic hostid
(`lib.substring 0 8 (builtins.hashString "sha256" hostname)`), no
concurrent host access. The threat model doesn't realistically apply.
But upstream's recommendation is conservative for the broad userbase,
and the new 26.11 default is `false` — pinning `true` opts *out* of the
safer default.

**Cost of `false`:** after an unclean shutdown (kernel panic, hard
power loss), the next boot's root-pool import refuses and the system
fails to boot. Recovery: boot with `zfs_force=1` as a one-time kernel
parameter from the bootloader (systemd-boot's edit-then-boot flow).
For scheelite we have physical/console access, so this is acceptable.

The 4 commits earlier in this branch (one per host) pinned
`forceImportRoot = true` to silence the deprecation warning. Those
should be flipped to `false` to align with upstream guidance.

## Changes

Three parallel changes:

### 1. Disko config: switch all flippable datasets to legacy

In `nixos-configurations/scheelite/disko.nix`, change every
`options.mountpoint = "/path";` to `options.mountpoint = "legacy";`
across both pools — 28 datasets in `scheelite-tank0` and 14 in
`scheelite-root` (including `local/root`, `local/nix`, and the
`canmount=off` parent `safe/persist/postgres` for consistency).

The bare `canmount = "off"` parents `local` and `safe` have no
mountpoint property to flip, so they're untouched. Flipping
`safe/persist/postgres` (which has both `canmount=off` and a
mountpoint property) to legacy is functionally equivalent —
canmount=off prevents auto-mount regardless — but keeps the pool
property surface uniform: every mountable dataset is legacy, every
parent is canmount=off.

Keep each dataset's top-level `mountpoint = "/path"` — that drives the
NixOS `fileSystems` entry, which becomes the sole mounter once the
live pool property is also `legacy`.

The disko config update is a single commit. It represents the
*intended end state*; the live pool reaches that state in two phases
(below). Between Phase 1 and Phase 2, the live pool's `/` and `/nix`
will still have their old `mountpoint = "/path"` properties — the
disko config will document `legacy` ahead of the live pool catching
up. This transient inconsistency is acceptable; nothing in the boot
relies on disko matching live state (disko drives fresh installs,
not ongoing maintenance).

### 2. forceImportRoot = false on all 4 hosts (per-host commits)

For each of `argentite`, `cassiterite`, `malachite`, `scheelite`:
flip the existing `boot.zfs.forceImportRoot = true;` line to `false`
in the host's `nixos-configurations/<host>/default.nix`.

Per the repo's per-host-commits convention, this is 4 separate
commits. Use commit-message body to explain that we're following
the new upstream recommendation; the previous pin (`true`) was set to
silence the deprecation warning, but the safer course is the
conservative default.

### 3. Live pool migration on scheelite — Phase 1 (now)

The disko config only drives a fresh pool layout. The running pool's
properties have to be flipped by hand. `zfs set mountpoint=legacy`
unmounts the dataset, so services holding any path open have to be
stopped first.

Phase 1 covers everything except `local/root` (`/`) and `local/nix`
(`/nix`) — those can't be unmounted from a running system and are
deferred to Phase 2.

#### Tank0 migration

```fish
# Stop everything that holds any /tank0 path open
sudo systemctl stop \
  jellyfin jellyseerr-bootstrap.service seerr \
  stash stasharr.service stasharr-bootstrap.service \
  sonarr sonarr-anime radarr whisparr prowlarr \
  qbittorrent \
  paperless-web paperless-consumer paperless-scheduler paperless-task-queue \
  grafana loki prometheus prometheus-node-exporter prometheus-smartctl-exporter prometheus-zfs-exporter \
  homepage-dashboard.service glances \
  alloy recyclarr scrutiny pinchflat

# Unmount deepest-first
zfs list -H -o name -r scheelite-tank0 | sort -r \
  | while read ds; sudo zfs unmount $ds; or true; end

# Flip property on every tank0 dataset
zfs list -H -o name -r scheelite-tank0 \
  | while read ds; sudo zfs set mountpoint=legacy $ds; end
```

#### Root pool subset migration (Phase 1)

```fish
# Stop services that hold /home, /persist, or /persist/postgres paths.
# Caddy/kanidm/oauth2-proxy/grafana/loki/prometheus all keep state
# under /var/lib (bind-mounted from /persist), so they must stop too.
sudo systemctl stop \
  'container@postgres-*' \
  caddy kanidm oauth2-proxy adguardhome.service \
  homepage-dashboard.service grafana loki prometheus prometheus-node-exporter prometheus-smartctl-exporter prometheus-zfs-exporter \
  recyclarr scrutiny

# Unmount the flippable root-pool datasets, deepest-first
for ds in /persist/postgres/{nextcloud,immich,paperless,sonarr,sonarr-anime,radarr,whisparr,prowlarr,stasharr} /persist /home
  sudo umount $ds; or true
end

# Flip property
for ds in safe/persist/postgres/{nextcloud,immich,paperless,sonarr,sonarr-anime,radarr,whisparr,prowlarr,stasharr} safe/persist safe/home
  sudo zfs set mountpoint=legacy scheelite-root/$ds
end
```

#### Remount and reboot

```fish
sudo mount -a
sudo systemctl daemon-reload
sudo systemctl reboot
```

Post-reboot, every dataset except `/` and `/nix` has matching disko +
live properties. fstab units are the sole mounters for those.

### 4. Live pool migration — Phase 2: `/` and `/nix` (deferred)

`/` cannot be unmounted from a running system; `/nix` is held open by
every running process (every binary it executes references it). So
flipping their mountpoint property to `legacy` requires a state where
those datasets aren't mounted by this host. That means rescue media.

**Required:** a NixOS installer USB (or any Linux live media with ZFS
2.x and `zpool`/`zfs` available — the NixOS installer ISO ships with
both).

**Procedure** (scheduled as a separate maintenance window after Phase
1 has been verified to work for a few days):

```fish
# 1. Boot scheelite from a NixOS installer USB. Get a shell.

# 2. Import scheelite-root with no auto-mount, into an altroot so the
#    rescue env doesn't try to use it as its actual /.
sudo zpool import -N -R /mnt scheelite-root

# 3. Flip the two remaining datasets. The pool is imported but
#    nothing is mounted (because -N), so no busy errors.
sudo zfs set mountpoint=legacy scheelite-root/local/root
sudo zfs set mountpoint=legacy scheelite-root/local/nix

# 4. Verify the properties stuck.
sudo zfs get -H -o name,value mountpoint scheelite-root/local/root scheelite-root/local/nix
# both should show 'legacy'

# 5. Export the pool cleanly so the next boot can re-import without -f.
sudo zpool export scheelite-root

# 6. Remove the USB, reboot into scheelite normally.
```

**Why this works:** With both properties flipped to `legacy`, the
next boot's initrd-stage-1 still mounts `/` via the
`fileSystems."/"` entry (disko emits this; the entry stays even when
the dataset is legacy), using `mount -t zfs -o zfsutil
scheelite-root/local/root /sysroot`. `mount.zfs` accepts legacy
datasets via `zfsutil` mode — it doesn't require the dataset's
mountpoint property to be non-legacy. Same story for `/nix.mount`
in stage 2. After this, no path in either pool relies on ZFS
auto-mount; `zfs-mount.service` has nothing to do (every dataset is
legacy or `canmount=off`).

**Risk:** If `mount.zfs` in stage-1 initrd misbehaves with a legacy
root dataset, the boot fails to mount `/` and drops to initrd
emergency. Recovery: boot from the rescue USB again, re-flip
`mountpoint=/` on `scheelite-root/local/root` to restore the prior
state, reboot. The risk is low (this configuration is the standard
NixOS+ZFS recommendation in the manual and used by many users), but
have the rescue USB ready.

## Critical files

- `nixos-configurations/scheelite/disko.nix` — `options.mountpoint`
  flips on 42 datasets (28 tank0 + 14 root pool, including `local/root`,
  `local/nix`, and `safe/persist/postgres`).
- `nixos-configurations/argentite/default.nix` — `forceImportRoot = false`.
- `nixos-configurations/cassiterite/default.nix` — `forceImportRoot = false`.
- `nixos-configurations/malachite/default.nix` — `forceImportRoot = false`.
- `nixos-configurations/scheelite/default.nix` — `forceImportRoot = false`.

## Verification

### Phase 1 (immediate) — after live migration + reboot

Pre-reboot, on the migrated system:

```fish
# Tank0 should all be legacy
zfs get -H -o value mountpoint -r scheelite-tank0 | sort -u    # legacy

# Root pool: / and /nix still '/' and '/nix'; rest legacy
zfs get -H -o name,value mountpoint -r scheelite-root | grep -v 'canmount\|@'

# All targets still mounted
for p in /tank0 /tank0/media /tank0/services /home /persist /nix /
  mountpoint $p
end

systemctl --failed --no-pager                              # 0
```

Post-reboot:

```fish
journalctl -b -u tank0.mount             # clean mount, no "not empty" warning
systemctl --failed --no-pager            # 0 — emergency mode no longer trips
mountpoint /tank0 /home /persist          # all mounted
```

`/nix` and `/` may still race today (race resolves favorably due to
stage-1 timing), so don't assume the boot is fully safe until Phase 2.

### Phase 2 (deferred) — after rescue-boot migration + reboot

```fish
# All datasets in both pools are legacy or canmount=off
zfs get -H -o value mountpoint scheelite-root/local/root scheelite-root/local/nix    # both legacy

# systemd handles every mount; zfs mount -a has nothing left to do
systemctl status zfs-mount.service        # active (exited), no mounts performed
journalctl -b -u nix.mount               # clean
systemctl --failed --no-pager            # 0
```

After Phase 2 confirmed, no path in either pool relies on ZFS
auto-mount. The race is closed.

### forceImportRoot=false validation

This only matters on unclean shutdowns; can't easily test without
risking the pool. Best confidence: normal `systemctl reboot` (clean
shutdown → clean export → clean import) continues to work, which it
will. The behavior change only manifests after a panic / hard power
loss, recoverable via `zfs_force=1` at the bootloader.

## Out of scope (deferred)

- The 3 services flagged in grafana earlier (`jellyseerr-bootstrap`,
  `oauth2-proxy`, `prowlarr-downloadclients`) were casualties of the
  chaotic activation cascade, not independent regressions. Address
  separately if they recur after a clean boot.

## Commits

5 commits total:

1. `nixosConfigurations.scheelite: switch tank0 + flippable root datasets to legacy mountpoint`
2. `nixosConfigurations.argentite: set boot.zfs.forceImportRoot = false`
3. `nixosConfigurations.cassiterite: set boot.zfs.forceImportRoot = false`
4. `nixosConfigurations.malachite: set boot.zfs.forceImportRoot = false`
5. `nixosConfigurations.scheelite: set boot.zfs.forceImportRoot = false`

Commit-message bodies should explain:
- (1) The race between zfs-mount.service and fstab units; why legacy
  fixes it. The disko config sets every flippable dataset (including
  `/` and `/nix`) to legacy as the *intended* end state; the live
  pool reaches it in two phases — Phase 1 (now: tank0 + most root
  pool, doable from a running system) and Phase 2 (deferred: `/` and
  `/nix`, requires rescue-boot maintenance).
- (2-5) Following upstream recommendation; the prior pin (`true`) was
  set to silence the deprecation warning, but `false` is the safer
  default — scheelite's dedicated-storage threat model means the
  bypassed safeguards don't realistically protect against anything,
  but the conservative default is upstream-aligned. Acceptable
  trade-off: occasional kernel-param `zfs_force=1` recovery after
  unclean shutdown.
