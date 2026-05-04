# Declarative \*arr / Jellyfin / qBittorrent on scheelite

**Status:** Active
**Started:** 2026-04-27
**Owner:** djacu
**Related:** `scheelite-homelab-services.md`

## Context

Sonarr, Radarr, Whisparr, Prowlarr, Jellyfin, qBittorrent, and Seerr each
keep most of their configuration in their own SQLite database, populated
through a web UI. That gap leaves a NixOS-driven homelab in the awkward
state of "I declared which services exist but had to click through their
setup wizards anyway." This design takes that gap to zero — every initial
configuration step is declared in Nix and pushed by an idempotent systemd
one-shot on every `nixos-rebuild switch`.

## Architecture

Four layers, applied in order at every activation:

### Layer 1 — Upstream `services.<name>` modules

Service-level config (port, dataDir, package, user, hardening). Untouched.

### Layer 2 — Env-var injection from sops

The .NET-based \*arr stack supports `<APP>__<SECTION>__<KEY>` environment
variables (verified in upstream Sonarr `Bootstrap.cs:111` —
`services.Configure<AuthOptions>(config.GetSection("Sonarr:Auth"))` —
combined with `.AddEnvironmentVariables()` at line 257). The upstream
NixOS module exposes this as `services.<name>.environmentFiles` (a list of
EnvironmentFile paths) and `services.<name>.settings` (an attrset that
upstream auto-converts via `mkServarrSettingsEnvVars`).

Pattern in our wrapper modules:

```nix
services.sonarr = {
  environmentFiles = [ config.sops.templates."sonarr.env".path ];
  settings = {
    server = { port = 8989; bindaddress = "127.0.0.1"; };
    auth = { method = "Forms"; required = "DisabledForLocalAddresses"; };
    postgres = { host = "127.0.0.1"; port = 5436; user = "sonarr"; ... };
  };
};

sops.secrets."sonarr/api-key".owner = "sonarr";
sops.secrets."sonarr/postgres-password".owner = "sonarr";

sops.templates."sonarr.env".content = ''
  SONARR__AUTH__APIKEY=${config.sops.placeholder."sonarr/api-key"}
  SONARR__POSTGRES__PASSWORD=${config.sops.placeholder."sonarr/postgres-password"}
'';
```

The API key is a pre-generated UUID committed to `secrets/scheelite.yaml`.
The same UUID is read at runtime by both the \*arr binary (env var) and our
REST one-shots (curl wrapper reading the sops file directly). One source
of truth. No `config.xml` templating needed — the env var wins over the
config file's stored value (see Sonarr's `ConfigFileProvider.cs`:
`var apiKey = _authOptions.ApiKey ?? GetValue("ApiKey", GenerateApiKey())`).

### Layer 3 — Recyclarr (TRaSH-Guides sync)

Wraps `services.recyclarr` (in nixpkgs at
`nixos/modules/services/misc/recyclarr.nix`). Pulls custom-format and
quality-profile recommendations from the TRaSH-Guides community repo
on a daily timer.

Configured templates (per the homelab plan's 4K/UHD lock):

- Sonarr (main): `web-2160p-v4`
- Sonarr-anime: `anime-sonarr-v4`
- Radarr: `sqp/sqp-1-web-2160p`

Recyclarr handles the bulk of the "release-selection brain" — hundreds of
custom formats (HDR, HEVC, release-group flags, codec preferences) and
their scoring inside quality profiles. Without it, those would be ~1000
lines of hand-authored Nix to maintain.

API keys passed via systemd `LoadCredential` (handled by the upstream
recyclarr module's `genJqSecretsReplacement` helper). Recyclarr never
touches the API key files directly; systemd copies them into the service's
isolated credential directory at startup.

### Layer 4 — Custom REST one-shots

Helper library at `library/declarative-arr.nix` exposes the building blocks
(re-exported via `theonecfg.library.declarative pkgs` in service modules):

| Helper | Purpose |
|---|---|
| `mkSecureCurl` | Wraps `curl` with `X-Api-Key` from a sops file. Returns a derivation; binary at `$out/bin/curl-<name>`. |
| `waitForApiScript` | Bash snippet — wait for `GET <url>` to respond 200, with timeout. Used in systemd `script` and `preStart`. |
| `mkArrApiPushService` | Generic \*arr endpoint reconciler. Args: `{ name, after, baseUrl, apiKeyFile, endpoint, items, comparator, finalize }`. Emits a systemd one-shot that GETs current state, diffs against `items` (Nix-declared), POST/PUT/DELETEs to reconcile. |
| `mkJellyfinBootstrap` | Runs the `/Startup/{Configuration,User,RemoteAccess,Complete}` sequence. Idempotent — checks if `/Startup/Configuration` returns 401 (= wizard already done). |
| `mkJellyfinLibrarySync` | POST/DELETE on `/Library/VirtualFolders` to reconcile libraries. Authenticates as admin via `/Users/AuthenticateByName`. |
| `mkQbtPushService` | Cookie-auth (or localhost bypass) + `/api/v2/app/setPreferences` + categories. |
| `qbtPasswordHashScript` | Bash one-shot that computes PBKDF2-SHA512-100k of a sops plaintext and sed-injects into `qBittorrent.conf`. Used as an extra `ExecStartPre` after upstream's config install. |

Shared option types in `library/arr-types.nix` (re-exported as
`theonecfg.library.arrTypes`):

- `rootFolderType` — `{ path }` for `/api/v3/rootfolder`.
- `indexerType`, `applicationType`, `downloadClientType`,
  `delayProfileType` — freeform attrs matching each \*arr's API JSON
  schema (refer to `GET /api/.../schema`). Comparator is `name`.
- `jellyfinLibraryType` — `{ paths, type, options }`.

## Per-service mapping

| Service | Layer 2 (env vars) | Layer 3 (Recyclarr) | Layer 4 (one-shots) |
|---|---|---|---|
| sonarr | `SONARR__AUTH__APIKEY`, `SONARR__POSTGRES__*` | `web-2160p-v4` | `sonarr-{rootfolders,downloadclients,delayprofiles}` |
| sonarr-anime | same prefix `SONARR__`; separate env file | `anime-sonarr-v4` | `sonarr-anime-{rootfolders,downloadclients}` |
| radarr | `RADARR__*` | `sqp/sqp-1-web-2160p` | `radarr-{rootfolders,downloadclients}` |
| whisparr | `WHISPARR__*` | (Recyclarr unsupported) | `whisparr-{rootfolders,downloadclients}` |
| prowlarr | `PROWLARR__*` | n/a | `prowlarr-{indexers,downloadclients,indexerproxies,applications}`. The applications one-shot auto-derives from enabled \*arr modules and injects each *arr's API key from sops at runtime. |
| jellyfin | minimal (no early API surface) | n/a | `jellyfin-bootstrap` (run-once via /Startup/*), `jellyfin-libraries` (auto-derived from enabled \*arr/pinchflat) |
| qbittorrent | `qBittorrent.conf` via `serverConfig`; PBKDF2 password via preStart | n/a | `qbittorrent-config` (preferences + categories per \*arr) |
| pinchflat | minimal | n/a | n/a — small enough to live entirely in NixOS module options |
| jellyseerr (services.seerr) | TBD — see deferred section | n/a | TBD — bootstrap deferred (see below) |

## Auto-derivation between modules

Several modules infer their config from the enabled state of others:

- **Prowlarr applications** auto-link to whichever of
  `theonecfg.services.{sonarr,sonarr-anime,radarr,whisparr}` are enabled.
  Each gets a Prowlarr `Application` registration with the matching
  implementation, baseUrl from the \*arr's port, and apiKey injected from
  the \*arr's sops file at runtime.
- **qBittorrent categories** auto-derive a category per enabled \*arr
  pointing at `${downloadsDir}/<name>` (e.g., `radarr` →
  `/tank0/downloads/radarr`).
- **Jellyfin libraries** auto-derive from enabled \*arr / pinchflat:
  - `sonarr.enable` → `TV Shows` library at `/tank0/media/tv` (tvshows)
  - `sonarr-anime.enable` → `Anime` at `/tank0/media/anime` (tvshows)
  - `radarr.enable` → `Movies` at `/tank0/media/movies` (movies)
  - `pinchflat.enable` → `YouTube` at `/tank0/media/youtube` (homevideos)

All auto-derivation is opt-out via `<module>.autoLinkArrs = false` (or
`autoCategories = false`, `autoLibraries = false`) and supplemented by
explicit `<module>.applications` / `extraCategories` / `extraLibraries`
options.

## Sonarr-anime: second Sonarr instance

NixOS' upstream `services.sonarr` is a singleton. The anime instance is
built from scratch in `nixos-modules/services/sonarr-anime/module.nix`:

- A separate `systemd.services.sonarr-anime` unit using `pkgs.sonarr` as
  the binary, with hardening cloned from upstream.
- A separate `users.users.sonarr-anime` system user (uid auto-allocated;
  /var/lib/nixos persists the assignment via impermanence).
- Its own postgres instance at port 5437 (`sonarr-anime-main` +
  `sonarr-anime-log` databases).
- Its own port (8990), data dir (`/tank0/services/sonarr-anime`), and root
  folder (`/tank0/media/anime`).
- Its own env file (`sonarr-anime/env`) and api-key (`sonarr-anime/api-key`)
  in sops.

The anime instance reuses the same Layer-4 helpers as the main Sonarr —
`mkArrApiPushService` doesn't care about being the second copy.

## qBittorrent password handling — B-lite

From `scheelite-homelab-services.md`'s qBittorrent decision:

1. `serverConfig.Preferences.WebUI.AuthSubnetWhitelistEnabled = true` and
   `AuthSubnetWhitelist = "127.0.0.1/32"` — auth bypassed for loopback
   (Caddy + our one-shots). LAN access is gated by Caddy + oauth2-proxy.
1. The PBKDF2 hash is **not** placed in `serverConfig` (avoids putting it
   in the world-readable Nix store).
1. `qbtPasswordHashScript` runs as an extra `ExecStartPre` AFTER upstream's
   config-install ExecStartPre, computing the hash from a sops plaintext
   and sed-injecting it into the config. Idempotent — only writes if the
   `Password_PBKDF2` line is missing or its value is empty.

The password is a defense-in-depth layer for the case where the WebUI is
accidentally bound to LAN; in normal operation, the localhost bypass means
the password is never exercised.

## Idempotency and reconciliation

Every Layer-4 one-shot follows the same shape:

```
1. Wait for the target API to respond (timeout 5min).
2. GET current state (list of items at the endpoint).
3. Read declarative items (a JSON file in the Nix store).
4. For each declared item:
     - If an item with the same `comparator` value exists → PUT (update by id).
     - Else → POST (create).
5. For each existing item NOT in declared:
     - DELETE.
```

This means: re-running `nixos-rebuild switch` always re-converges to the
declared state. Manual changes via the web UI get overwritten on next
activation — the Nix config is the source of truth.

The diff/reconcile loop is in `mkArrApiPushService` (`library/declarative-arr.nix`)
and Prowlarr's inline applications one-shot.

## What's NOT covered yet

- **Jellyseerr first-run wizard** is a multi-step OAuth-against-Jellyfin
  flow. Doable but not yet implemented. Currently Jellyseerr is shipped
  as "click-through-once" — the only manual step in the entire stack.
  Tracked in `nixos-modules/services/jellyseerr/module.nix` as a TODO.
- **Custom Jellyfin branding** (logo, custom CSS) — would use
  `/Branding/Configuration` POST. Helper not yet written.
- **Jellyfin plugin install** — would use `/Plugins/...` endpoints.
  Helper not yet written.
- \**Kanidm OIDC provisioning for *arr / Jellyfin** — \*arr v3 doesn't
  really support OIDC in a useful way (no per-user RBAC). Jellyfin SSO
  via plugin (`jellyfin-plugin-sso`) would need its own one-shot to push
  config. Out of scope this iteration.
- **LimeTorrents → Radarr push fails Prowlarr's auto-test.** Investigated
  on 2026-05-03. Prowlarr's app-sync runs an empty-term sanity check
  before pushing an indexer to an \*arr; for LimeTorrents the response
  is parsed as 0 results in the Movies category, so Radarr never gets
  it. Sonarr (TV/anime categories) passes the same check.

  Root cause is in the bundled Cardigann YAML (`Prowlarr/Indexers
  definitions/v11/limetorrents.yml`):

  ```yaml
  paths:
    - path: "{{ if .Keywords }}search/all/{{ .Keywords }}/{{ .Config.sort }}/1/{{ else }}/latest100{{ end }}"
  ```

  Empty-keyword browse hits `/latest100` (a single global recent-uploads
  endpoint, not category-specific), then Cardigann post-filters by
  category. When the latest 100 happens to be light on movies, the
  Movies post-filter returns 0 → auto-test fails → Radarr push skipped.
  LimeTorrents itself does have a category-specific browse at
  `/browse-torrents/<Category>/`, but the YAML doesn't use it.

  Real keyword searches from Radarr would work — they hit `search/all/...`
  and post-filter, which returns hits for any real movie title. The
  auto-test is the only thing blocking Radarr registration.

  Fix options, not pursued this round:
  1. Manual Torznab add via Radarr's UI (one-time; bypasses the test;
     drifts from declarative state).
  2. Local Cardigann YAML override at `<prowlarr-data>/Definitions/Custom/limetorrents.yml`
     using `/browse-torrents/<Category>/` for empty-keyword browse and
     adjusted row selectors. Most "right" fix but requires carrying a
     small local fork of one upstream YAML.
  3. Upstream PR to `Prowlarr/Indexers`.

  Currently (4) — accept the loss. Radarr has YTS (movies-dedicated)
  and Nyaa.si (anime movies); LimeTorrents-as-movies is marginal
  overlap. Revisit when (a) we add a private movie tracker and want
  LimeTorrents as a fallback or (b) LimeTorrents becomes Radarr's only
  realistic source.

## Files

Created:

- `library/declarative-arr.nix`
- `library/arr-types.nix`
- `nixos-modules/services/sonarr-anime/module.nix`
- `nixos-modules/services/recyclarr/module.nix`
- `nixos-modules/services/jellyseerr/module.nix`
- `nixos-configurations/scheelite/disko.nix`

Modified:

- `library/default.nix` (re-exports declarative + arrTypes)
- `nixos-modules/services/{sonarr,radarr,whisparr,prowlarr,jellyfin,qbittorrent}/module.nix`
- `nixos-configurations/scheelite/{default,impermanence}.nix`

## Verification (per service, after deployment)

```sh
# *arr health (Sonarr / Radarr / Whisparr): API key from env reaches the binary
curl -fsS -H "X-Api-Key: $(sops decrypt secrets/scheelite.yaml | yq -r .sonarr.api-key)" \
  http://sonarr.scheelite.lan/api/v3/system/status | jq .version

# Root folders reconciled
curl -fsS -H "X-Api-Key: $key" http://sonarr.scheelite.lan/api/v3/rootfolder \
  | jq '.[] | .path'   # → "/tank0/media/tv"

# Prowlarr applications linked to all enabled *arr instances
curl -fsS -H "X-Api-Key: $prow_key" http://prowlarr.scheelite.lan/api/v1/applications \
  | jq '.[] | .name'   # → "Sonarr", "Sonarr (Anime)", "Radarr", "Whisparr"

# Jellyfin wizard complete
curl -fsS http://jellyfin.scheelite.lan/Startup/Configuration | jq -r '.ServerName'
# → "scheelite" (or whatever serverName is set)

# Jellyfin libraries match declared
curl -fsS -H "X-Emby-Token: $jellyfin_token" \
  http://jellyfin.scheelite.lan/Library/VirtualFolders \
  | jq '.[] | .Name'   # → "TV Shows", "Anime", "Movies", "YouTube"

# qBittorrent categories per *arr
curl -fsS http://qbittorrent.scheelite.lan/api/v2/torrents/categories \
  | jq 'keys'   # → ["sonarr", "sonarr-anime", "radarr", "whisparr"]

# Recyclarr daily sync
journalctl -u recyclarr.service -b 0 | tail
```
