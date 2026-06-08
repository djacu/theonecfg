# scheelite ZFS legacy migration — refined retry

## Why this plan exists

Yesterday's attempt failed; the resulting postmortem misdiagnosed
the cause as "disko + legacy + zfsutil incompatibility." That
diagnosis was wrong — disko gates `zfsutil` on
`config.options.mountpoint != "legacy"`
(`disko/lib/types/zfs_fs.nix:177`), so legacy datasets correctly
get fstab entries without `zfsutil`. The actual failure root cause
is **unresolved**: the rescue-USB-time reproduction `mount -t zfs -o zfsutil ... legacy` was a known-bad combination, but the
explanation for why both new and previous generations failed at
boot has not been pinned conclusively.

This plan addresses every finding from the adversarial review of
the prior retry draft. Before any deploy step, we verify the
rendered fstab against expectations.

## Finding-by-finding response

### F1 — Verify rendered fstab via nix eval *before* deploying

Build the proposed scheelite generation without activating; inspect
what it would actually produce. Run on malachite or a workstation:

```fish
nix build .#nixosConfigurations.scheelite.config.system.build.toplevel --no-link --print-out-paths
# inspect the generated /etc/fstab inside the build result
nix eval --json '.#nixosConfigurations.scheelite.config.fileSystems."/persist".options'
nix eval --json '.#nixosConfigurations.scheelite.config.fileSystems."/tank0".options'
nix eval --json '.#nixosConfigurations.scheelite.config.fileSystems."/persist/postgres/sonarr".options'
```

**Acceptance:** every flipped dataset shows `options = []` (no
`zfsutil`). Every non-flipped dataset (`/`, `/nix`) shows
`options = ["zfsutil"]`.

If a flipped dataset still has `zfsutil` after `options.mountpoint = "legacy"` in disko — **stop**. That contradicts disko's documented
behavior; investigate the option merge / mkDefault interaction
before doing anything else. Yesterday's failure most likely was
this, and proceeding without confirmation would replay it.

### F2 — `zfs-mount-generator` and other auto-mount sources

Before deploy, check:

```fish
systemctl list-unit-files | grep -i zfs-mount
systemctl cat zfs.target zfs-mount.service 2>/dev/null
ls /etc/systemd/system/zfs.target.wants/
ls /etc/systemd/system/zfs-import.target.wants/
```

If `zfs-mount-generator` is enabled (it can generate `.mount` units
from `/etc/zfs/zfs-list.cache/<pool>`), those generated units may
conflict with fstab-generated ones. NixOS typically does *not*
enable this generator by default, but verify before committing.
**Acceptance:** no `zfs-mount-generator`-emitted units for any of
the affected paths.

### F3 — `/`, `/nix` are excluded from the flip

The previous draft re-applied commit `c05e803` wholesale, which
flipped *every* dataset including `local/root` (`/`) and `local/nix`
(`/nix`). That creates an unbootable state: their live pool
mountpoints stay as paths (can't be unmounted from a running
system), but their fstab would have no `zfsutil` (because disko
sees legacy in config). Mismatch → mount.zfs refuses → unbootable.

**This plan flips only the datasets that can be live-migrated:**

- `scheelite-tank0`: pool root (rootFsOptions keep `none`; no
  explicit dataset def) + 28 child datasets → flip 28 child datasets
  to legacy.
- `scheelite-root`: `safe/home`, `safe/persist`,
  `safe/persist/postgres` (canmount=off), all 9
  `safe/persist/postgres/*` children → flip 12 datasets.

Total: **40 flipped, not 42.** `local/root` and `local/nix` stay
as path mountpoints; their race is deferred to a rescue-USB
maintenance window (Phase 2 in the prior plan; still deferred).

### F4 — Disko config change

Modify `nixos-configurations/scheelite/disko.nix`:

- For all 28 `scheelite-tank0` child datasets, change
  `options.mountpoint = "/tank0/<path>"` → `options.mountpoint = "legacy"`.
- For the 12 `scheelite-root` datasets listed above, do the same.
- Leave `local/root`, `local/nix` unchanged (path mountpoints).
- Leave the `canmount=off` parents `local`, `safe` untouched (they
  have no mountpoint property).

Single commit. `forceImportRoot=true` already in place from
yesterday's revert work; no change.

### F5 — Activation chaos — use `boot`, not `switch`

Yesterday's first emergency mode happened during `nixos-rebuild switch` itself, as the activation cascade reloaded mount units
against datasets that were in flux. To avoid replay:

1. Deploy the new config via `sudo nixos-rebuild boot --flake .#scheelite`. This writes the new system but does **not**
   activate it; the running system stays on the current generation,
   no service restarts, no mount-unit reloads.
1. Do the live pool migration (next section) while the system
   continues to run on the old generation with its existing fstab
   intact.
1. Reboot. The new generation activates from scratch — no
   reload-cascade race.

### F6 — Live migration: band-aids are *not* avoidable, they are correct

The prior draft claimed lazy-unmount and `zfs set -u` were
band-aids that wouldn't be needed in a clean retry. That's wrong.
`/persist`'s bind-mounts to `/var/log`, `/etc/machine-id`,
`/etc/ssh/ssh_host_*` are held by `systemd-journald`, `sshd` (the
operator's own session), and other always-running processes that
can't be stopped on a live system. `/home` is held by the
operator's session. **`zfs set -u` is the supported tool for
exactly this case** (set property without remounting). Acknowledge
and use.

Migration script (no claims about band-aids being avoidable):

```fish
# Identify timers that could fire mid-migration and mask them
sudo systemctl stop stash-maintenance.timer recyclarr.timer
sudo systemctl mask --runtime stash-maintenance.timer recyclarr.timer

# Stop services holding /tank0 paths (tank0 datasets are
# unmount-able once these are down)
set tank0_svcs jellyfin jellyseerr-bootstrap.service seerr stash stasharr.service stasharr-bootstrap.service sonarr sonarr-anime radarr whisparr prowlarr qbittorrent paperless-web paperless-consumer paperless-scheduler paperless-task-queue grafana loki prometheus prometheus-node-exporter prometheus-smartctl-exporter prometheus-zfs-exporter homepage-dashboard.service glances alloy recyclarr scrutiny
sudo systemctl stop $tank0_svcs

# Stop postgres containers explicitly (wildcards don't expand for
# systemctl; enumerate)
set postgres_containers container@postgres-nextcloud container@postgres-immich container@postgres-paperless container@postgres-sonarr container@postgres-sonarr-anime container@postgres-radarr container@postgres-whisparr container@postgres-prowlarr container@postgres-stasharr
sudo systemctl stop $postgres_containers

# Stop other /persist-holders (not journald/sshd/machine-id holders;
# those stay running and require zfs set -u)
sudo systemctl stop caddy kanidm oauth2-proxy adguardhome.service

# Tank0: unmount deepest-first, skip pool root, flip
zfs list -H -o name -r scheelite-tank0 \
  | grep -v '^scheelite-tank0$' \
  | sort -r \
  | while read ds
sudo zfs unmount $ds; or true
end
zfs list -H -o name -r scheelite-tank0 \
  | grep -v '^scheelite-tank0$' \
  | while read ds
sudo zfs set mountpoint=legacy $ds
end

# Root-pool postgres children: unmount + flip (containers stopped)
for ds in immich nextcloud paperless prowlarr radarr sonarr sonarr-anime stasharr whisparr
sudo umount /persist/postgres/$ds; or true
sudo zfs set mountpoint=legacy scheelite-root/safe/persist/postgres/$ds
end

# Root-pool postgres parent (canmount=off, just set property)
sudo zfs set -u mountpoint=legacy scheelite-root/safe/persist/postgres

# /persist itself: cannot unmount (journald/machine-id/sshd holds);
# zfs set -u sets the property without touching the mount
sudo zfs set -u mountpoint=legacy scheelite-root/safe/persist

# /home: operator session holds it; zfs set -u
sudo zfs set -u mountpoint=legacy scheelite-root/safe/home

# Verify all flipped
zfs get -H -o name,value mountpoint -r scheelite-tank0 \
  | grep -v '^scheelite-tank0	'
zfs get -H -o name,value mountpoint -r scheelite-root \
  | grep -vE '	(none|/|/nix)$'
```

### F7 — Reboot semantics with mismatched bind-mounts

After the live migration, `/persist` and `/home` are still
mounted at their paths (we used `-u`); the property is now
`legacy`. Impermanence bind-mounts under `/persist` continue to
work via the existing mount. Some services may have written to
inconsistent state during the property flip — that's OK because
we're about to reboot.

```fish
sudo systemctl reboot
```

On reboot the new generation activates from scratch:

- Initrd imports both pools (`forceImportRoot=true` provides the
  safety net for the root pool; tank0 has no analog but the
  current shutdown will export it cleanly).
- Initrd mounts `/sysroot` from `scheelite-root/local/root`
  (still path mountpoint + zfsutil → works).
- Initrd mounts `/sysroot/persist` from
  `scheelite-root/safe/persist` (now legacy mountpoint + no
  zfsutil → works).
- Main systemd starts. `zfs-mount.service` runs `zfs mount -a`
  which skips every legacy dataset — nothing to mount, no race.
- fstab mount units mount `/tank0`, `/home`, `/persist/postgres/*`
  etc. via plain `mount.zfs` (no zfsutil) on legacy datasets.
- Impermanence's activation script re-creates the bind-mounts.

### F8 — Tank0 has no `forceImportRoot` safety net

`forceImportRoot=true` only force-imports the root pool. Tank0 is
in `boot.zfs.extraPools` and imports via
`zfs-import-scheelite-tank0.service`, gated by
`boot.zfs.forceImportAll` (which we do **not** set). If tank0's
in-use flag is left dirty by an unclean shutdown, the next boot's
tank0 import refuses and tank0.mount fails (without recovering
the host into emergency.target — it'd just be that services
needing tank0 fail).

**Mitigation:** A `systemctl reboot` is a clean shutdown — tank0
will be properly exported. The risk is only if the reboot is
*not* clean (panic / power loss during the migration window). To
shrink that window, do the migration in one continuous session
without unnecessary pauses.

**Not a mitigation:** no rescue USB path is provided here for
tank0 dirtiness because `zpool import -f` from the running system
works to fix it. If it happens, the recovery is `sudo zpool import -f scheelite-tank0 && systemctl restart …`.

### F9 — Forward-only migration / old generations become unbootable

After the live property flip, every older generation in
systemd-boot has an fstab with `zfsutil` against a now-legacy
live pool — same mismatch that broke yesterday's
previous-generation fallback. Before deploying:

1. Identify and remove pre-migration generations that we don't
   want a sleep-deprived operator booting by mistake:

   ```fish
   sudo nix-collect-garbage --delete-older-than 1d
   sudo /run/current-system/bin/switch-to-configuration boot
   ```

   This drops most older generations while preserving the
   current running one (which we're about to replace via
   `boot`).

1. Pin the *current* (pre-migration) generation as a labeled
   recovery option:

   ```fish
   ls /nix/var/nix/profiles/system-*-link  # find latest pre-migration profile
   # the systemd-boot menu will still show it; we explicitly
   # don't garbage-collect it
   ```

   Document in the deploy notes: "if migration boot fails, do
   NOT pick generation <N>; only the rescue USB recovers from
   this state."

### F10 — Rollback via rescue USB

If the post-reboot system fails to boot or comes up broken,
revert the live pool from the NixOS installer USB (same procedure
as yesterday). Documented here so the operator doesn't have to
piece it together under stress:

```bash
# Boot NixOS installer USB on scheelite
sudo -i

# Import both pools without auto-mount, altroot to /mnt
zpool import -f -N -R /mnt scheelite-root
zpool import -f -N -R /mnt scheelite-tank0

# Revert tank0 child datasets to paths
zfs set -u mountpoint=none scheelite-tank0
for ds in $(zfs list -H -o name -r scheelite-tank0 | tail -n +2); do
  mp="/${ds#scheelite-tank0/}"
  zfs set -u mountpoint="$mp" "$ds"
done

# Revert root pool flipped datasets to paths
zfs set -u mountpoint=/home scheelite-root/safe/home
zfs set -u mountpoint=/persist scheelite-root/safe/persist
zfs set -u mountpoint=/persist/postgres scheelite-root/safe/persist/postgres
for svc in immich nextcloud paperless prowlarr radarr sonarr sonarr-anime stasharr whisparr; do
  zfs set -u mountpoint="/persist/postgres/$svc" "scheelite-root/safe/persist/postgres/$svc"
done

# Verify, export, reboot
zfs list -r scheelite-tank0
zfs list -r scheelite-root
umount /mnt 2>/dev/null || true
zpool export scheelite-tank0
zpool export scheelite-root
sync
reboot
```

After this, scheelite is back to pre-migration state and a
pre-migration generation can boot.

### F11 — Postmortem rewrite

After this migration completes (success or failure), the
existing
`docs/plans/completed/scheelite-zfs-hardening-postmortem.md`
needs to be replaced — not patched. Multiple sections are built
on the wrong premise:

- TL;DR
- "The trap" (entire section)
- "Root causes" (#1 specifically)
- "What we should have done"
- "What's deferred"

**This is a separate commit, written after we have a final
outcome to report.** Don't update it speculatively in the same
commit as the migration; the migration's outcome determines what
the corrected analysis should say.

Same for the memory file `feedback_zfs_legacy_zfsutil_trap.md` —
remove or rewrite based on outcome.

### F12 — Other small fixes (already incorporated above)

- Dataset count: **40 flippable** (28 tank0 + 12 root pool).
- Loop skips pool root (`grep -v '^scheelite-tank0$'`).
- Postgres containers enumerated explicitly (no wildcards).
- Stop list includes timers (`stash-maintenance.timer`,
  `recyclarr.timer`) and masks them to prevent re-firing.

## Critical files

- `nixos-configurations/scheelite/disko.nix` — flip 40 datasets
  (not 42; `/` and `/nix` stay as paths).
- `docs/plans/completed/scheelite-zfs-hardening-postmortem.md` —
  rewrite post-migration.
- Memory file `feedback_zfs_legacy_zfsutil_trap.md` — rewrite or
  remove post-migration.

## Execution order

1. **Pre-deploy:** build via `nix build` (no activation), verify
   `fileSystems."/persist".options == []` and other flipped paths
   the same, verify non-flipped paths still have `zfsutil`. If any
   mismatch — stop, investigate, do not deploy.
1. **Inspect `zfs-mount-generator` state.** If active for any
   affected path — stop, investigate.
1. **Garbage-collect old generations.** Reduce the surface area
   of "wrong generation to boot if migration fails."
1. **Make the disko config change** (single commit).
1. **Push the branch.**
1. **`sudo nixos-rebuild boot --flake .#scheelite`** on scheelite
   (NOT switch). Verify with `nix-store -qR /run/booted-system` vs `/run/next-boot-system` that next-boot
   points at the new generation.
1. **Live migration** per script above.
1. **`sudo systemctl reboot`.**
1. **Watch the console** for clean boot.
1. If clean: SSH in, verify per below.
1. If broken: rescue USB, revert per F10.
1. **Postmortem rewrite** as a separate follow-up commit.

## Verification (post-reboot, if clean)

```fish
systemctl --failed --no-pager
mountpoint /tank0; mountpoint /home; mountpoint /persist; mountpoint /
zfs get -H -o name,value mountpoint -r scheelite-tank0
zfs get -H -o name,value mountpoint -r scheelite-root
journalctl -b -u tank0.mount
journalctl -b -u zfs-mount.service
```

Expected:

- `--failed`: empty or just known-flaky reconcilers.
- All mountpoints active.
- All flipped datasets show `legacy`; `/`, `/nix` show paths;
  pool roots show `none`.
- `tank0.mount` journal: clean `Mounted /tank0.`, no
  `zfs_mount_at` errors, no `directory not empty` warnings.
- `zfs-mount.service` journal: ran but `mount -a` had nothing
  to mount (no failures, no successes).

**Additionally**: do 3 consecutive reboots (`systemctl reboot`)
to gain confidence the boot is structurally clean and not just
this-time-lucky. Verify post each reboot.

## What this plan does *not* do

- Does not flip `/` or `/nix` (deferred to rescue-USB Phase 2).
- Does not change `boot.zfs.forceImportRoot` (stays `true`).
- Does not pre-emptively rewrite the postmortem (post-outcome).
- Does not build a full VM test (acknowledged as the right thing
  but blocked on scheelite-pool-layout simulation work; the
  pre-deploy `nix eval` gate is the lighter substitute).

## Stop conditions

If any of these occur during execution, **halt and reassess**:

- `nix eval` shows `zfsutil` in a flipped dataset's options.
- `zfs-mount-generator` is active for any affected path.
- The post-reboot `tank0.mount` journal shows any
  `zfs_mount_at` error or `directory not empty` warning.
- Any service holds `/persist`, `/home`, or `/tank0` open after
  the stop step (visible via `lsof | grep` or `fuser`).
- Two of the three consecutive reboot tests are not clean.

In any of these cases, perform the rescue-USB rollback before
attempting further changes.
