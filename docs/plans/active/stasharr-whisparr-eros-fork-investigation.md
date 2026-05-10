# Stasharr ↔ Whisparr fork mismatch — follow-up investigation

## What surfaced

End-to-end smoke test of Stasharr Portal (Phase 4.2 of
`investigate-stash-stasharr-portal-and-delegated-beacon.md`) failed at
the "submit scene request" step. Stasharr's Whisparr adapter calls
`GET http://127.0.0.1:6969/api/v3/movie?stashId=<uuid>` to look up
whether the requested scene already exists; Whisparr 2.0.0.2151 (the
nixpkgs build) returned `404 Not Found` because that endpoint does
not exist in this Whisparr.

## Why

Whisparr has split into two upstream branches with incompatible APIs:

- **`v2-develop`** (default; nixpkgs `pkgs.whisparr` 2.0.0.2151) —
  Sonarr-v3 fork. API is series/episode-shaped:
  `/api/v3/series`, `/api/v3/episode`. No `/movie` controller exists.
  Verified by `find ./src/Whisparr.Api.V3 -name "*.cs" | grep -i
  movie` returning nothing on the cloned source.

- **`eros`** — Radarr-fork. API is movie-shaped:
  `/api/v3/movie`, `MovieController.AllMovie(int? tmdbId, string
  tpdbId, string stashId, …)` — accepts `stashId` as a query
  parameter exactly the way Stasharr's adapter expects. Verified at
  `src/Whisparr.Api.V3/Movies/MovieController.cs:175,199` of
  Whisparr's `eros` branch.

Stasharr's adapter (`apps/sp-api/src/providers/whisparr/whisparr.adapter.ts:708-713`)
hard-codes the eros (Radarr-fork) URL shape:

```ts
parsed.pathname = `${cleanPath}/api/v3/movie`;
parsed.searchParams.set('stashId', stashId);
```

There is no version negotiation, no fallback. The adapter only knows
how to talk to the Radarr-fork variant.

## What works regardless

The PHash-against-StashDB workflow that motivated Phase 1 is fully
solved by Stash standalone. Stasharr's catalog browsing
(`StashDB → Discover`) and local-availability badge (queries Stash for
matching scenes in `/tank0/media/adult`) work because both depend on
StashDB and Stash, not Whisparr. Only the "Request → Whisparr"
side of Stasharr is broken.

## Why a quick patch isn't trivial

Patching Stasharr's adapter to talk to Whisparr v2-develop's
`series/episode` API would be more than a URL rewrite:

1. **Data-model mismatch.** Stasharr models adult content as
   `SceneIndex` records keyed by a single `stashId`. Whisparr
   v2-develop models content as `Series` containing `Episodes`. A
   one-to-one map between a StashDB scene and a Whisparr v2 entity
   doesn't exist — most StashDB scenes are standalone scene releases
   (per-studio singles), which Whisparr v2 doesn't have a first-class
   abstraction for.
2. **Lookup semantics.** Stasharr's `findMovieByStashId(stashId)`
   relies on Whisparr indexing a foreign-id called `stashId` per
   movie. Whisparr v2's series have `tvdbId`, `tmdbId`, `imdbId`
   (no `stashId`). Episodes aren't externally identified at all in
   the same way.
3. **Submit flow.** Stasharr posts a movie-create with `{stashId,
   monitored, …}`. Whisparr v2 has no equivalent endpoint that takes
   a stashId and provisions a corresponding entity — the workflow
   shape is different.

A working patch would either:

- **(a) Add a Stasharr backend mode** that toggles between
  "movie-shape API" (eros) and "series-shape API" (v2-develop), with
  a separate adapter module per shape and a config flag selecting
  one. Probably 2-4 weeks of upstream work assuming the maintainer
  agrees the use case justifies the complexity.
- **(b) Deploy Whisparr eros (Radarr-fork) alongside or instead of
  v2-develop**, configure Stasharr against eros. Avoids patching
  Stasharr at all, at the cost of a second Whisparr instance (two
  postgres DBs, two queues, two import paths) or a migration off
  v2-develop.

## Concrete next steps if pursued

### Option B — Whisparr eros via OCI (cheaper)

1. Add a `theonecfg.services.whisparr-eros` module wrapping
   `virtualisation.oci-containers.containers.whisparr-eros` against
   `ghcr.io/hotio/whisparr:v3` (eros) or upstream's pre-built image.
   Use a separate port and a separate postgres instance.
2. Repoint `theonecfg.services.stasharr.integrations[type="WHISPARR"].baseUrl`
   to the eros container.
3. Decide whether v2-develop Whisparr stays for the existing
   workflow or gets retired. Two Whisparrs is operationally noisy
   (separate queues / configs / indexer-lists in Prowlarr).

Estimated effort: 4-8 hours including testing.

### Option A — patch Stasharr upstream

1. Open an issue on `enymawse/stasharr-portal` describing the
   v2-develop incompatibility.
2. Propose adding a `WHISPARR_API_FLAVOR` (or similar) env var
   selecting between movie-shape and series-shape adapters.
3. Implement the series-shape adapter end-to-end (browse, lookup,
   submit, queue probe, hasFile check). Whisparr's
   `src/Whisparr.Api.V3/Series/SeriesController.cs` and
   `Episodes/EpisodeController.cs` are the controller-side
   reference.

Estimated effort: high (2-4 weeks of focused upstream work),
contingent on maintainer interest.

## Decision recorded for now

User picked option 2 ("keep current Whisparr, accept Stasharr can't
request") on 2026-05-10. The Stash module remains live and serves
the original PHash-on-mega-pack motivation. Stasharr stays deployed
because its catalog UI and local-availability badge still provide
value; the broken request button is a known limitation. Revisit if
the Stasharr request flow becomes worth the operational cost.
