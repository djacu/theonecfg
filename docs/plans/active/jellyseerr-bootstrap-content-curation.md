# jellyseerr-bootstrap: connection vs. content-curation gaps

## Context

`nixos-modules/services/jellyseerr/module.nix` runs a one-shot
`jellyseerr-bootstrap.service` on first deploy that:

1. Logs into Seerr via Jellyfin auth (creating the Seerr admin user).
2. Registers each enabled *arr (Sonarr, Sonarr-anime, Radarr) via
   `/api/v1/settings/{sonarr,radarr}`.
3. POSTs `/api/v1/settings/initialize` to mark setup complete.

The bootstrap is idempotent: it short-circuits if
`/api/v1/settings/public.initialized` is already `true`, so
re-running it post-deploy does nothing.

That works fine for *connection* registration — hostnames, ports,
API keys all land. What it doesn't do well is *content curation*:
choosing which quality profile, which root folder, which Jellyfin
libraries are active. Those fields get filled in with values that
turn out wrong in practice, leaving the admin to fix them in the
Seerr UI on first run.

This doc enumerates the gaps and the open decision on how to handle
them.

## Gap 1 — Quality profile drift after Recyclarr

**Symptom**: Seerr requests stay `Requested` indefinitely; Radarr
either doesn't pick them up or rejects every release silently.

**Cause**: bootstrap reads `/api/v3/qualityprofile` from each *arr
and picks index `[0]` (`activeProfileId`, `activeProfileName`).
At first-deploy time, only the *arr's stock defaults exist
(`Any`, `HD-1080p`, etc.). Recyclarr runs *later* (it's daily
timer-driven), creates the curated profile (`SQP-1 WEB (2160p)`,
`WEB-2160p`, `[Anime] Remux-1080p`), and may remove the stock
profile Seerr was pointing at. Seerr is now holding a stale
profile ID.

**Where it lives**:
`nixos-modules/services/jellyseerr/module.nix` lines ~213-215
(the `profileId` / `profileName` jq filters).

## Gap 2 — Root folder doesn't show selected in v3.2.0 UI

**Symptom**: `*arr` entry in Seerr shows the Default Root Folder
dropdown as empty/unselected, even though the bootstrap registered
`activeDirectory`.

**Cause**: probably an API-shape mismatch between what older
Jellyseerr accepted and what v3.2.0's UI binds to. Stored value
exists internally; the dropdown just doesn't render it. Re-selecting
in UI and saving fixes it.

**Where it lives**: same bootstrap, `activeDirectory` field in the
registration payload.

## Gap 3 — Jellyfin libraries not toggled on

**Symptom**: Seerr's Settings → Jellyfin shows libraries (TV / Anime /
Movies / Adult) listed but all *unchecked*. Effect: Seerr can't sync
availability from Jellyfin, so requests stay `Requested` forever
even after Radarr/Sonarr import the title.

**Cause**: bootstrap registers Jellyfin via the auth flow but never
calls `/api/v1/settings/jellyfin/library` to enable libraries. They
land in Seerr's config disabled by default.

**Where it lives**: bootstrap script, after the Jellyfin login step.
There's no library-enable step at all.

## Decision space (open — not yet decided)

### Option A: Add curation steps to bootstrap

Make the bootstrap fully populate post-registration:
- After Jellyfin login, fetch library list via Seerr API and POST
  to `/api/v1/settings/jellyfin/library` with all libraries enabled.
- Look up quality profile by *name* (configurable per-instance,
  defaulting to the recyclarr-managed names) instead of `[0]`.
- For root folder, re-select after registration to force UI binding.

**Pros**: zero-touch deploy. Bootstrap fully reconciles intended
state.

**Cons**:
- Couples the jellyseerr module to recyclarr's profile naming.
  If `recyclarr.radarrQuality` is changed (e.g. 4K → 1080p,
  swapping the template's profile name) the jellyseerr fallback
  silently picks `[0]` again — a non-obvious failure.
- Bootstrap idempotency gets complicated: should it overwrite
  user choices on subsequent runs? If yes, admin can't customize
  via UI. If no, it has to detect a "first run" state, which is
  fragile.
- More API surface to maintain across Seerr version bumps. v3.2.0
  already broke `baseUrl: "/"` (now `""`) and quietly changed how
  the root folder dropdown binds.

### Option B: Drop content curation, document the manual step

Trim the bootstrap to *only* the connection / auth steps:
- Skip `qualityprofile` query
- Drop `activeProfileId` / `activeProfileName` / `activeDirectory`
  from the registration payload
- Don't try to enable Jellyfin libraries

Document the one-time admin steps in the module's comment block:
"After first deploy, in the Seerr UI:
- Settings → Services → [each *arr] → pick Default Quality Profile
  + Default Root Folder, save.
- Settings → Services → Jellyfin → check the libraries you want
  Seerr to track."

**Pros**:
- Honest about the actual division of labor: Nix configures
  *infrastructure*; Seerr UI handles *editorial choices*.
- Survives Recyclarr profile-name churn and Seerr API drift.
- Less code to maintain.
- Matches upstream Seerr's design intent (admin makes these
  choices once via the wizard).

**Cons**:
- First deploy isn't self-completing. New host needs a manual
  UI session.
- Easy to forget the manual step and wonder why requests stall
  (we just lived this).

### Option C: Hybrid — set what's stable, defer what's volatile

- Auto-enable Jellyfin libraries (stable: library names come from
  the jellyfin module's auto-derived list, not from a third-party
  schedule).
- Skip quality profile + root folder selection (volatile: depends
  on Recyclarr and on Seerr's UI binding quirks).

**Pros**: covers the gap that's most surprising to admins (the
Jellyfin library toggle, which has no obvious UI hint that it
needs to be set), without coupling to Recyclarr.

**Cons**: still needs the same documentation as Option B for the
other two gaps. Mixed approach is harder to reason about than a
clean "all in" or "none in".

## Recommendation pending

Not decided. Lean is somewhere between Option B (cleanest) and
Option C (one more piece of UX rough-edge handled).

Decision drivers when we revisit:

- **How often will Recyclarr profile names change?** If we expect
  to switch templates or quality presets in the next year, Option
  A's coupling is more painful.
- **How many hosts will run jellyseerr?** Currently one (scheelite).
  At one host, the manual UI step is a one-time chore. At three+,
  it's a recurring chore that argues for automation.
- **How tolerant are we of post-bootstrap admin config drift?**
  Option B implicitly accepts that UI state can diverge from
  declarative config; Option A tries to keep them in sync at the
  cost of complexity.

## Already fixed (separate from this decision)

These were bootstrap bugs we did fix in-place:

- `is4k = true` on Sonarr / Radarr — semantic was wrong; flag means
  "dedicated 4K instance in a 1080p+4K split", not "supports 4K
  content". Set to `false` for the single-instance case. Symptom
  was: Seerr had no non-4K target and stalled all requests.
- `baseUrl: "/"` — v3.2.0 rejects trailing slash in the URL Base
  field. Changed to empty string.
