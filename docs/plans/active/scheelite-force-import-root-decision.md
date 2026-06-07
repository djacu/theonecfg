# scheelite — decide `boot.zfs.forceImportRoot` policy

Status: active (investigation only — outcome not predetermined)
Owner: dan
Last updated: 2026-06-01

## Why this plan exists

`<nixpkgs>/nixos/modules/tasks/filesystems/zfs.nix:355-358` defines:

```nix
forceImportRoot = lib.mkOption {
  type = lib.types.bool;
  default = lib.versionOlder config.system.stateVersion "26.11";
  ...
};
```

The default flipped from `true` to `false` at `stateVersion = 26.11`.
Upstream considers `false` safer (force-import on an unclean root
pool can mask corruption). Lines 700–710 emit a warning ONLY when the
option is *unset and using the default-true*:

> `boot.zfs.forceImportRoot` is using the default value of `true`. It
> is highly recommended to set it to `false`, the new default from
> 26.11 on, to reduce the risk of data loss. Alternatively, you can
> silence this warning by explicitly setting it to `true`.

All four nixosConfigurations here (`argentite`, `cassiterite`,
`malachite`, `scheelite`) already explicitly set
`boot.zfs.forceImportRoot = true`, so no warning is firing.

This plan answers the *next* question: should we follow upstream's
26.11 default (`false`), or keep the explicit `true` because of
empirical evidence from this host?

The May 2026 attempt to flip bundled it with the pool migration and
caused a brick — saved as memory in `feedback_pool_migration_caution`.
Lesson: never bundle. This plan covers the unbundled decision.

## Investigation questions

### Q1 — What does `forceImportRoot` actually control?

`<nixpkgs>/nixos/modules/tasks/filesystems/zfs.nix:744` and `:800`:
the value gates `ZFS_FORCE="-f"` in the initrd's pool import script,
and `force = cfgZfs.forceImportRoot` in
`createImportService` for `rootPools`. Effect is scoped to **root
pool import in initrd only**.

It does NOT affect `tank0`. tank0 is in `boot.zfs.extraPools` and
imports via the generated `zfs-import-scheelite-tank0.service` whose
`force` flag is `boot.zfs.forceImportAll` (default `false`). We do
not set `forceImportAll` anywhere, so tank0 already imports without
`-f`.

### Q2 — What's the actual failure surface of flipping to `false`?

If the root pool's "in-use" flag is dirty (panic, power loss,
OOM-killed shutdown, watchdog reset), initrd's `zpool import scheelite-root` returns non-zero. With `forceImportRoot=false` we do
NOT pass `-f`, so the import fails.

**Recovery options, in increasing cost:**

1. **Boot with `zfs_force=1` kernel parameter.** No rescue USB
   needed. systemd-boot's edit feature is disabled by default on
   NixOS (`boot.loader.systemd-boot.editor` defaults to `false`), so
   this requires explicit prep — either re-enable the editor or
   build a recovery-mode systemd-boot entry with the param baked in.
1. **Rescue USB**: import + export + reboot, per the prior plan's
   F10 pattern.

The prior plan's "rescue USB" framing missed (1). Worth documenting
on this host explicitly — and possibly enabling the systemd-boot
editor for this host (or providing a `zfs_force=1` recovery entry)
as a prerequisite for the flip.

### Q3 — How often does scheelite have unclean shutdowns?

```fish
last -x reboot shutdown | head -30
journalctl --list-boots | head -20
journalctl _COMM=systemd-shutdown -b -1 --no-pager | tail -30
```

If clean shutdowns dominate (orderly reboot, normal poweroff), the
empirical risk of leaving the pool dirty is low and `false` is
defensible. If there's a history of OOM-killed shutdowns / power
events / panics, `true` is empirically saving us and the rationale
for keeping it is stronger.

### Q4 — Is there an `forceImportAll` interaction?

`<nixpkgs>/nixos/modules/tasks/filesystems/zfs.nix:678-680` asserts
that if `forceImportAll = true` then `forceImportRoot` must also be
`true`. Currently we set neither (well, we set `forceImportRoot = true`). If anyone later considers `forceImportAll = true` for
recovery, they'll need `forceImportRoot = true` to satisfy the
assertion. This isn't blocking, just a coupling to note.

### Q5 — Do laptops have the same considerations?

`feedback_zfs_legacy_migration` notes laptops don't worry about
concurrent imports of the same system. But unclean shutdown is
*more* likely on a laptop (battery, lid-close, sleep weirdness), not
less. So laptops are an even stronger case for keeping `true`. Or
the opposite: laptops auto-resume from suspend so often that the
"force-import" gymnastics rarely fire. Decide per-host based on Q3
findings.

## Possible outcomes

1. **Flip to `false` on scheelite.** Q3 shows clean shutdowns
   dominate. Q2's `zfs_force=1` recovery path is documented and
   tested. Land as a single per-host commit per
   `feedback_per_host_commits`. The other hosts get their own
   decisions.
1. **Keep `true` explicitly on all hosts.** No warning fires (we set
   it explicitly). Document the rationale in the option's surrounding
   comment in each host's `default.nix`, including the May 2026
   incident as evidence.
1. **Mixed**: `false` on scheelite (well-tested recovery path),
   `true` on laptops (different shutdown profile).

The plan does not assume outcome (1).

## Baking criterion (deliberately TBD)

If outcome is (1) or (3), the question is when. Concrete options to
debate:

- N consecutive clean reboots over M days
- After the next NixOS minor bump (validates that we're not just
  lucky on the current kernel/zfs combo)
- After the `/` and `/nix` legacy-migration plan completes
  (one set of major rootfs changes at a time)

Pick before deploy. Don't ship vague.

## Definition of "monitor" after the deploy

If outcome (1) or (3):

- `journalctl -b 0 -u zfs-import-scheelite-root.service` — exit code
  0, no `cannot import` warnings.
- `zpool status scheelite-root` — `state: ONLINE`, no errors, no
  scrub-needed flag.
- `systemctl --failed` — empty.
- 3× `sudo systemctl reboot` over 3 days, same checks each time.

If any check fails, immediate revert (next bullet).

## Rollback

If a deploy of `false` reveals a real unclean-pool scenario and the
host won't boot:

1. **Try `zfs_force=1` kernel parameter first.** systemd-boot menu
   → edit (if editor enabled) or pre-baked recovery entry. Boots the
   same generation with the force-import escape hatch back in.
1. **If (1) fails or editor not available**: rescue USB, import + export,
   reboot.
1. Once up: `git revert <commit> && nixos-rebuild switch --flake .#<host>` to restore the explicit `true`.

## Exit criteria

- Q1–Q5 answered and recorded in this doc (or in a follow-on commit
  to it).
- Outcome chosen (with rationale).
- If outcome (1) or (3): baking criterion picked and met before
  deploy; `zfs_force=1` recovery path verified (test boot with the
  param on a non-broken state to confirm the entry / editor works).

## What this plan does *not* do

- Does not flip during the pending `/` and `/nix` legacy-migration
  plan. Never bundle pool property migrations with this flag again.
- Does not touch `forceImportAll`.
- Does not assume the answer is "yes flip it." A defensible outcome
  is "explicit `true` permanently, documented."
