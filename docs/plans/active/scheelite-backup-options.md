# scheelite backups — options

**Status:** Postponed (no decision)
**Started:** 2026-04-26
**Owner:** djacu
**Related:** `scheelite-homelab-services.md` (Phase 6 is gated on the choice captured here)

## Context

The original homelab plan included a `theonecfg.services.restic-backups` module
that would run restic against a repo on `/tank0/backups/<name>` for each service.
While drafting it, we caught a structural flaw: the source data and the "backup"
both live on the same ZFS pool. If the pool dies, both copies die. That isn't
backup — it's at best a defense against accidental deletion within a service,
and **ZFS snapshots are strictly better** at that role: instant, atomic, take
no space until divergence, restorable in seconds with `zfs rollback` or
`zfs clone`.

So the restic-backups module was scrapped, and the backup design moved into
this doc to revisit deliberately later.

The job to be done is two-tier:

1. **Local recovery** — fast, frequent, restores from "I deleted the wrong
   thing" or "the database corrupted itself five minutes ago." Operates within
   scheelite. Granularity: per-dataset or per-file. Recovery time: seconds.
1. **Disaster recovery (off-site)** — survives the house burning down. Stored
   somewhere physically separate. Granularity: per-snapshot or per-archive.
   Recovery time: hours, mostly bound by network egress.

Each tier has independent tool choices.

## Tier 1 — Local recovery

### Option 1A: ZFS snapshots via `services.sanoid`

Sanoid is a small Perl tool that creates and prunes ZFS snapshots on a
schedule. NixOS module: `services.sanoid`. Highly declarative.

```nix
services.sanoid = {
  enable = true;
  datasets."scheelite-tank0/tank0/services" = {
    autosnap = true;
    autoprune = true;
    hourly = 24;
    daily = 30;
    monthly = 12;
    yearly = 0;
    recursive = true;
  };
  datasets."scheelite-root/safe/persist" = {
    autosnap = true;
    autoprune = true;
    hourly = 24;
    daily = 30;
    monthly = 12;
    recursive = true;
  };
};
```

**Pros**

- Native to ZFS; near-zero overhead. Snapshots are atomic, instantaneous, and
  cost no space until data diverges.
- Per-dataset retention policy.
- Recovery is trivial: `zfs rollback`, `zfs clone`, or `cd .zfs/snapshot/<name>`.
- Pairs cleanly with `syncoid` for off-site replication (Tier 2 option 2A).
- Already-popular with NixOS homelabs.

**Cons**

- Snapshots are local; pool failure loses all snapshots. Not a Tier 2 substitute.
- For databases (postgres specifically), a raw filesystem snapshot might catch
  a half-committed transaction. Need `pg_dump`-equivalent or wait-for-quiesce
  at snapshot time, OR rely on postgres' own crash-recovery to replay WAL.
  Postgres typically recovers cleanly from a snapshot of `$PGDATA`, but it's
  worth noting.

### Option 1B: ZFS snapshots via `services.zfs.autoSnapshot`

NixOS-native option (no extra tool). Less flexible than sanoid; uses
`zfs-auto-snapshot` in the kernel package.

```nix
services.zfs.autoSnapshot = {
  enable = true;
  flags = "-k -p";
  frequent = 4;   # 15-min interval
  hourly = 24;
  daily = 7;
  weekly = 4;
  monthly = 12;
};
```

**Pros**

- No extra package, no extra config files.
- Same semantics as sanoid for the core "snapshot + prune" job.

**Cons**

- Per-dataset retention is harder to express (single global policy).
- Less commonly recommended by ZFS-on-Linux community than sanoid.

### Option 1C: skip local recovery layer

Skip snapshots; rely entirely on Tier 2 for any recovery. Acceptable if Tier 2
is reasonably fast and frequent, but means accidental-delete recovery requires
pulling from off-site.

Cheap to add later, so this is a pragmatic "don't block on it" option.

## Tier 2 — Off-site / disaster recovery

### Option 2A: `syncoid` replicates ZFS snapshots to a remote pool

`syncoid` (sibling of sanoid) does `zfs send | ssh remote zfs receive` between
hosts. Fast, incremental, and preserves snapshots verbatim. NixOS option:
`services.syncoid`.

```nix
services.syncoid = {
  enable = true;
  commands."tank0/services" = {
    source = "scheelite-tank0/tank0/services";
    target = "backup-host:rpool/scheelite-mirror/services";
  };
};
```

**Pros**

- Block-level efficient: only changed extents go over the wire.
- Snapshot fidelity: every local snapshot you take is replicated. Fast restore.
- Preserves all ZFS properties (encryption, compression, etc).
- Pairs naturally with sanoid (Tier 1 1A).

**Cons**

- Requires a remote host that runs ZFS and accepts SSH. Easiest options:
  - A second NixOS box you own (different physical location ideally).
  - A rented VPS with a ZFS-compatible volume (rare, expensive).
  - A NAS with ZFS on a friend's network.
- "Cloud" object stores (S3/B2) are NOT compatible with `zfs send` directly.
  Some adapters exist (`zfsbackup-go`, `znapzend → tar → S3`) but none are as
  clean.
- If the remote host fails, you lose your off-site copy.

### Option 2B: restic to cloud object storage (B2 / S3 / R2)

Restic does deduplicated, encrypted backups to many backends including
Backblaze B2, S3-compatible stores (Cloudflare R2, Wasabi, AWS S3), SFTP,
local disk.

```nix
services.restic.backups.scheelite-offsite = {
  paths = [
    "/tank0/services"
    "/persist/postgres"
    "/persist"
  ];
  repository = "b2:scheelite-backups:/restic";
  passwordFile = config.sops.secrets."restic/repo-password".path;
  environmentFile = config.sops.secrets."restic/b2-env".path; # B2_ACCOUNT_ID, B2_ACCOUNT_KEY
  timerConfig = { OnCalendar = "daily"; Persistent = true; };
  pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 12" ];
  initialize = true;
};
```

**Pros**

- Off-site by construction; no second host needed.
- Encrypted client-side (provider sees ciphertext only).
- Deduplicated: lots of small versions cost little.
- Mature, widely deployed, good NixOS module.
- Backblaze B2 pricing is friendly: ~$6/TB/month storage + low egress.
- Works with literally any provider that has a Restic backend.

**Cons**

- Restore time bounded by network bandwidth (restoring 1TB at 100 Mbps = ~24h).
- Recurring monthly cost (B2: ~$6/TB/month + egress on restore).
- Backing up postgres requires either a `pg_dump` pre-hook or trusting
  filesystem-level consistency (same caveat as ZFS snapshots).
- Requires careful repo password management — lose the password and the
  backup is unreadable.

### Option 2C: rsync-based to a local NAS / external drive

`rsync` to a local NAS or USB drive that's swapped offsite periodically.
NixOS module: `services.borgbackup` (borg is rsync-shaped but encrypted and
deduplicated; better than raw rsync for our needs).

**Pros**

- Local NAS is fast (gigabit, no internet egress).
- Cheap if you already have a NAS; effectively zero recurring cost.
- Encrypted (borg) or not (raw rsync).

**Cons**

- "Local NAS" is the same physical location as scheelite. Without manual
  rotation off-site, the NAS catches the same disaster as scheelite.
- USB-drive rotation requires discipline.

### Option 2D: hybrid — ZFS snapshots locally + restic to B2 weekly

Most homelabs land here. ZFS snapshots provide the fast-recovery tier.
A weekly (or daily) restic push to B2 gives true off-site disaster recovery.
Two tools, two responsibilities, no overlap.

**Pros**

- Best ratio of recovery speed (snapshots) to disaster resilience (restic+B2).
- Each tool is doing what it's good at.
- Cheap: B2 charges for actual storage, dedup keeps it small.

**Cons**

- Two systems to maintain instead of one.
- Two restore workflows to remember.

## Postgres specifically

Database backups deserve a separate thought because filesystem-level snapshots
can capture a database in an in-flight state.

For our per-service postgres containers, options:

- **Trust postgres crash recovery.** A filesystem snapshot of `$PGDATA` taken
  while postgres is running is roughly equivalent to a hard kill — postgres
  replays WAL on next start and recovers. Works for the homelab use case.
  Snapshots that include the per-service `/persist/postgres/<name>` data dir
  give us this implicitly.
- **`pg_dump` per service before snapshot.** Run `pg_dump <name>` from inside
  the postgres container (or via psql client on the host) into a file under
  `/tank0/services/<name>/db-dumps/`, then snapshot. Restore is a clean
  `psql < dump.sql`.
- **WAL archiving.** Continuous archiving for PITR — overkill here.

**Recommendation:** trust crash recovery for our scale. If we ever care about
point-in-time-precision for a specific service (vaultwarden comes to mind),
add a `pg_dump` pre-hook on its restic job at that time.

## Comparison summary

| | Tool(s) | Off-site | Cost / month | Restore speed (local) | Restore speed (off-site) | Setup |
|---|---|---|---|---|---|---|
| **None** | n/a | no | $0 | n/a | n/a | n/a |
| **Tier 1 only — sanoid** | sanoid | no | $0 | seconds | n/a | minimal |
| **Tier 2 only — restic+B2** | restic | yes | ~$6/TB | n/a (restic restore) | hours | medium |
| **syncoid to remote ZFS** | sanoid+syncoid | yes (if remote is off-site) | depends on remote | seconds | minutes-hours | medium-high (need remote ZFS host) |
| **Hybrid — sanoid + restic+B2** | sanoid+restic | yes | ~$6/TB | seconds | hours | medium |

## My recommendation

For a homelab that's actively used and where loss-of-data would be painful:
**Hybrid — sanoid for local snapshots + restic to Backblaze B2 for off-site
disaster recovery.** This is the most common landing spot for ZFS-on-NixOS
homelabs and matches the two-tier job-to-be-done cleanly.

For a homelab that's still being stood up and where the data isn't yet
precious: **defer entirely** until the services are running and have data
worth losing. Adding either tier later is a clean follow-up.

## Where we left off

- The original plan had a `theonecfg.services.restic-backups` module with
  local-only repos on `/tank0/backups/<name>`. That module was deleted because
  same-pool repo is not a meaningful backup.
- ZFS snapshots are clearly the right tool for local recovery; we have not
  decided whether to use sanoid or `services.zfs.autoSnapshot`.
- Off-site destination is undecided. The choice between syncoid (needs ZFS
  remote) and restic-to-B2 depends partly on whether you ever stand up a
  second NixOS host or pay for a small ZFS-capable VPS.
- Vaultwarden is gated on this — we agreed not to self-host it until backups
  are real and a restore drill has been done end-to-end.

## Open questions to resolve when revisiting

- Do you have or plan to acquire a second always-on host that could receive
  ZFS snapshots? (NAS, second NixOS box, friend's homelab via
  Tailscale/WireGuard.)
- What's an acceptable recurring cost for off-site? Backblaze B2 at ~$6/TB/mo
  scales linearly with how much you back up. Storj / Wasabi / R2 are
  alternatives with different pricing curves.
- What data retention do you actually want? Hourly for a week + daily for a
  month + monthly for a year is common; could be tighter or looser.
- Postgres consistency: trust crash recovery, or wire up `pg_dump` pre-hooks?
  For most services, the former is fine.
- Test-restore cadence: an untested backup is not a backup. Once an off-site
  is wired up, schedule a quarterly drill where you restore a service to a
  scratch dataset and verify it comes up clean.
