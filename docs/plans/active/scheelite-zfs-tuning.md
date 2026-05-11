# scheelite ZFS dataset tuning

Investigation of four ZFS topics that influence the disko.nix property
choices. Findings inform the per-dataset `recordsize`, `compression`,
`checksum`, and `dedup` settings, plus host-side `nix.settings.auto-optimise-store`
and per-instance postgres tuning. All recommendations applied to the repo;
this doc captures the *why*.

## TL;DR

| Question | Conclusion |
|---|---|
| Is `compression=zstd` worth it over `lz4`? | **Yes.** zstd has built-in LZ4-first early-abort — incompressible data costs ~LZ4, compressible data gets zstd ratio. Strict upgrade. |
| Best `recordsize` for postgres datasets? | **`16K`.** vadosware bench shows ~24 % TPS over aligned 8K. Larger windows for compression without read-amp. |
| Should we override postgres `withBlocksize=16`? | **No (this round).** Locks the on-disk format; recordsize alone gets the bulk of the win; revisit only if benchmarks demand it. |
| Should we enable ZFS dedup on `local/nix`? | **No.** `nix.settings.auto-optimise-store` already file-level hardlinks /nix/store. ZFS block dedup adds DDT RAM cost for marginal gain. |
| Should we enable ZFS dedup elsewhere? | **No (default).** Run `zdb -S <pool>` to simulate first. Media/downloads/postgres pages dedup ratio ≈ 1.00. |
| Best `checksum`? | **`fletcher4`** (default). Cryptographic checksums (sha256, blake3) only matter for dedup/nopwrite/encryption-verify. The 7950X has AVX-512 → blake3 is fast, but unused without dedup. |
| Use `chksum_bench` to pick a compression algo? | **No — it benchmarks checksums, not compression.** No equivalent compression bench exists in OpenZFS. |

## Topic 1 — compression: zstd vs lz4

### What I assumed going in

"`compression=on` defaults to zstd with an lz4 fallback for incompressible data."

### What's actually true

- `compression=on` defaults to **LZ4** when the LZ4 feature flag is active
  (which it always is on a modern pool). It does **not** default to zstd.
- Setting `compression=zstd` enables a *two-pass* path with built-in
  early-abort: first the data is run through LZ4; if LZ4 itself can't
  compress, ZFS gives up early before invoking zstd at all. Source:
  [`module/zstd/zfs_zstd.c`](https://github.com/openzfs/zfs/blob/master/module/zstd/zfs_zstd.c)
  lines ~564–596 (`zstd_compress_early_abort`):
  > A zstd early abort heuristic. First, we try LZ4 compression, and if
  > it doesn't early abort, we [try zstd].
- Stats kept at `zstd_stat_lz4pass_allowed` / `_rejected` in `/proc/spl/kstat/zfs/zstd_stats`.

So `compression=zstd` is "zstd ratio for compressible data, ~LZ4 cost for
incompressible." There's no scenario where staying on plain `lz4` beats it.

### Recommendation

- Root pool + tank0 pool: **`compression=zstd`** (was `lz4`).
- `tank0/media`: keep `compression=zstd-1` (overridden) — media is already
  ratio-poor, zstd-1 is the cheapest variant.
- `tank0/downloads`: keep `compression=off` — torrent payloads are already
  compressed; ratio ≈ 1.00, just CPU waste.

There is no built-in compression-algorithm benchmark in OpenZFS (no
`compress_bench` kstat or analogous facility). To compare algorithms on
real workload, write a representative dataset under each setting and read
`zfs get compressratio,compressed,referenced` on the test dataset.

## Topic 2 — postgres recordsize and blocksize

### Stage 1: ZFS `recordsize`

Per [vadosware "Optimizing Postgres on ZFS on Linux"](https://vadosware.io/post/everything-ive-seen-on-optimizing-postgres-on-zfs-on-linux/#increasing-postgres-blocksize)
benchmark on default-block (8K) postgres against varying ZFS recordsize:

| recordsize | TPS | Δ vs 8K |
|------------|--------|--------:|
| 8K | 1366 | — |
| 16K | 1689 | +24 % |
| 32K | 1568 | +15 % |

OpenZFS [Workload Tuning](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html)
also recommends 16K, 32K, 64K, or 128K for postgres — not 8K, despite
postgres's 8K page size, because larger records give compression a wider
window and ZFS reads aren't strictly recordsize-aligned for sequential
postgres scans.

Best result in the article: **3630 TPS at recordsize=16K + zstd +
logbias=latency** vs. 1366 TPS baseline.

### Stage 2: postgres `--with-blocksize=N` (skipped)

[NixOS PR #411966](https://github.com/NixOS/nixpkgs/pull/411966) (merged
2025-05-30) added `withBlocksize` and `withWalBlocksize` overrides to
`pkgs.postgresql_<n>`. Values are kilobytes; `withBlocksize` 1–32,
`withWalBlocksize` 1–64. Default 8 KB. Sample usage:

```nix
services.postgresql.package = pkgs.postgresql_16.override {
  withBlocksize = 16;
  withWalBlocksize = 16;
};
```

**Compatibility caveats** (from the PR):

- The on-disk format is **not** cross-compatible. `pg_upgrade` cannot move
  data between builds with different block sizes.
- Block size is **compile-time only**; there is no `initdb --block-size`
  flag.
- The patch disables the in-tree regression test suite when overridden.
- Logical dump/restore is the only path back to default-block postgres.

### Why we picked recordsize=16K but skipped withBlocksize=16

- recordsize alone captures the dominant gain (`8K → 16K`: +24 %).
- The recordsize change is reversible (`zfs set recordsize=…` per dataset;
  takes effect for new writes only, but no commitment).
- The package override is a one-way decision per cluster.
- We can revisit if profiling shows the postgres workload is bottlenecked
  on the 8K/16K mismatch — but for a homelab where the postgres instances
  are tiny (sonarr metadata DB, nextcloud session store, etc.), the
  marginal gain doesn't justify the lock-in.

### Stage 3: postgres-side ZFS-friendly settings

These are added to **every** `services.postgresql.settings` block in
`nixos-modules/services/postgres/module.nix`:

| Setting | Default | We use | Reason |
|------------------------|--------:|-------:|--------|
| `full_page_writes` | `on` | `off` | ZFS COW makes torn pages impossible; FPW becomes pure write amplification (~50 % of WAL volume). |
| `wal_init_zero` | `on` | `off` | Pre-zeroing WAL segments is a no-op on COW (the zeros land in new blocks anyway). |
| `wal_recycle` | `on` | `off` | Recycling WAL segments assumes in-place overwrite is cheap; on COW each "overwrite" is a new block. |

References:

- [PostgreSQL docs: full_page_writes](https://www.postgresql.org/docs/current/runtime-config-wal.html)
- [vadosware article](https://vadosware.io/post/everything-ive-seen-on-optimizing-postgres-on-zfs-on-linux/) — same recommendations
- [Citus blog: "Tuning PostgreSQL on ZFS"](https://www.citusdata.com/blog/2017/09/29/what-makes-postgres-fast/) — same recommendations

## Topic 3 — dedup vs. `nix-store --optimise`

### What `nix-store --optimise` actually does

- Walks `/nix/store`, computes `SHA-256` over the NAR-serialized form of
  each file (content + executable bit), keeps one canonical inode at
  `/nix/store/.links/<hash>`, atomically renames duplicates to hardlinks
  of that inode.
- `nix.settings.auto-optimise-store = true` runs the same logic *inline*
  during every store write. Default is `false`.
- Source:
  [optimise-store.cc](https://github.com/NixOS/nix/blob/master/src/libstore/optimise-store.cc)
  uses `hashPath(..., FileSerialisationMethod::NixArchive, HashAlgorithm::SHA256)`.
- Cost: one SHA-256 per file written. On a 7950X with `~94 GiB RAM`,
  unmeasurable.
- Coverage: whole-file dedup. Two files dedup only if entire contents AND
  permission bits match. Nix manual cites typical savings of 25–35 % for
  /nix/store after optimise.

### What ZFS dedup does

- Block-level. Each `recordsize`-aligned block hashed and tracked in the
  on-disk DDT (Dedup Table).
- Memory cost per DDT entry: legacy ~320 B in ARC; OpenZFS 2.3 fast dedup
  ~216 B live + 144 B log.
- OpenZFS 2.3.0 (early 2024) shipped fast dedup:
  - PR [#15888](https://github.com/openzfs/zfs/pull/15888) ZAP shrinking
  - PR [#15889](https://github.com/openzfs/zfs/pull/15889) Dedup Quota
  - PR [#15890](https://github.com/openzfs/zfs/pull/15890) DDT Prefetch
  - Several follow-ups (15887/15892/15893/15894/15895) still open.
- nixpkgs unstable currently has zfs 2.4.1 → has fast dedup.

### The interaction

- If `--optimise` already hardlinked a file, only one set of blocks
  exists on disk. ZFS dedup would observe a single instance + refcount=1
  for it — adds DDT bookkeeping with zero gain on the already-deduped
  content.
- ZFS dedup *could* still catch identical *blocks* across non-identical
  files (shared ELF sections, common headers at the same offset within
  similarly-laid-out files), but for /nix/store the dominant duplication
  is whole-file (rebuilds producing byte-identical store paths), which
  --optimise already captures.
- Net: ZFS dedup on top of --optimise pays the DDT RAM/IO tax for
  marginal additional savings.

### Recommendation

- `scheelite-root/local/nix`: enable
  `nix.settings.auto-optimise-store = true`; leave `dedup=off`.
- `safe/persist/postgres/*`: `dedup=off`. Postgres 8K (or 16K) pages
  contain LSN/xid/checksum in headers — pages are essentially never
  byte-identical even within a single DB.
- `scheelite-tank0/media/*`: `dedup=off`. Already-compressed video/audio
  at recordsize=1M; entropy ≈ maximal, ratio ≈ 1.00.
- `tank0/downloads`: `dedup=off`. Same reason; compression also off.
- `safe/home`, `tank0/services/*`: `dedup=off` default. If you suspect
  duplication on a specific dataset, run `zdb -S <pool>` first — it
  simulates a DDT against the existing data and prints the projected
  ratio + memory cost without enabling anything. Only consider
  `dedup=verify` (never `dedup=on` — `verify` does a byte-compare to
  defend against SHA-256 collisions corrupting data) if the simulation
  shows ratio ≥ 2.0 *and* the dataset is small enough that DDT fits
  comfortably in ARC.

References:

- [Nix manual: nix-store --optimise](https://nix.dev/manual/nix/stable/command-ref/nix-store/optimise.html)
- [Nix manual: auto-optimise-store](https://nix.dev/manual/nix/stable/command-ref/conf-file.html)
- ["OpenZFS dedup is good now and you shouldn't use it"](https://despairlabs.com/blog/posts/2024-10-27-openzfs-dedup-is-good-dont-use-it/) — matches our reasoning
- [OpenZFS workload tuning: dedup](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html)

## Topic 4 — `/proc/spl/kstat/zfs/chksum_bench`

### What I had been told

"You can read this kstat to pick the optimal compression algorithm for
your machine."

### What it actually is

A **checksum** algorithm benchmark. Not compression. Source:
[`module/zfs/zfs_chksum.c`](https://github.com/openzfs/zfs/blob/master/module/zfs/zfs_chksum.c)
in `chksum_run()` times `cs->func(abd, size, ctx, &zcp)` (a single
checksum invocation) and reports `MiB/s` for each `<algo>-<impl>`
combination.

Algorithms covered: `edonr`, `skein`, `sha256`, `sha512`, `blake3`. Block
sizes: 1k, 4k, 16k, 64k, 256k, 1m, 4m, 16m. Implementation variants:
`generic`, `ssse3`, `avx`, `avx2`, `avx512`, `shani`, `sse2`, `sse41`, `x64`.

Per the manpage [`zfs.4`](https://github.com/openzfs/zfs/blob/master/man/man4/zfs.4):

> If multiple implementations of BLAKE3 are available, the fastest will
> be chosen using a micro benchmark.

It exists so OpenZFS can auto-select the fastest implementation of each
checksum algorithm at module load. Reading the kstat triggers a fresh
benchmark.

### Implication for scheelite (Ryzen 7950X — Zen 4 with AVX-512)

Per the source's representative numbers (tested on i3-1005G1, but
relative ordering on Zen 4 is similar):

| algo / impl | 16k MiB/s | 256k MiB/s |
|-------------------|----------:|-----------:|
| edonr-generic | 1769 | 1783 |
| sha256-shani | 1212 | 1233 |
| blake3-avx512 | 5269 | 5872 |

`blake3-avx512` is the clear winner at most block sizes, beating
`sha256-shani` ~5×. **However**, default `checksum=fletcher4` is
essentially free (vector arithmetic over the block), and is what's used
for non-dedup data. There's no reason to switch to a cryptographic
checksum unless we enable dedup, nopwrite, or encryption.

We don't enable any of those, so: keep `checksum=fletcher4` everywhere.

### No compression-bench facility exists

GitHub code search for `compress_bench` in the openzfs/zfs repo: zero
hits in src; only one match inside the vendored zstd's `xxhash.h` (a
zstd-internal name, not a zfs-exposed kstat). Practical compression
algorithm comparison: write to a test dataset under each setting,
measure `compressratio`, `compressed`, `referenced`, `logicalused`.

## Applied changes (this round)

1. `nixos-configurations/scheelite/disko.nix`:
   - Root pool + tank0 pool: `compression=lz4 → zstd`.
   - All `safe/persist/postgres/*` datasets: `recordsize=8K → 16K`.
   - Comment block on each pool's `rootFsOptions` documenting the
     choice rationale (compression / checksum / dedup).
1. `nixos-modules/services/postgres/module.nix`:
   - Per-instance `services.postgresql.settings` adds
     `full_page_writes=false`, `wal_init_zero=false`, `wal_recycle=false`.
1. `nixos-configurations/scheelite/default.nix`:
   - `nix.settings.auto-optimise-store = true`.

## Not applied (flagged for revisit)

- `pkgs.postgresql_<n>.override { withBlocksize = 16; withWalBlocksize = 16; }`.
  Locks the cluster's on-disk format; revisit only if profiling shows
  postgres is page-size-bottlenecked.
- Per-dataset `dedup=verify` on `safe/persist` (small config files
  potentially share blocks). Run `zdb -S scheelite-root` after some
  baseline data to measure before deciding.

## Followups / verification when scheelite is online

- After install, verify the auto-fastest checksum impl was picked:
  ```sh
  cat /proc/spl/kstat/zfs/chksum_bench
  ```
- Spot-check compression ratios:
  ```sh
  zfs get compressratio,compressed,referenced scheelite-root/local/nix
  zfs get compressratio,compressed,referenced scheelite-root/safe/persist/postgres/sonarr
  zfs get compressratio,compressed,referenced scheelite-tank0/tank0/media/tv
  ```
- After a few weeks of usage, simulate dedup to confirm `dedup=off`
  remains the right choice:
  ```sh
  zdb -S scheelite-root
  zdb -S scheelite-tank0
  ```
  Both should show a "dedup ratio" near 1.00. If one shows ≥ 2.0 on a
  specific dataset, that's a signal to consider `dedup=verify` for that
  dataset only.
