# Plan: scheelite Homepage dashboard

**Status:** Active
**Started:** 2026-05-07
**Owner:** djacu
**Companion docs:**

- `scheelite-homelab-services.md` — phased rollout this dashboard sits on top of (phases 1–5 already landed)
- `scheelite-lan-access.md` — the `*.scheelite.dev` + Porkbun DNS-01 setup the dashboard's vhost relies on

## Context

scheelite is at the end of phase 5 of `scheelite-homelab-services.md`: foundation
(sops, Caddy with Porkbun DNS-01, AdGuard, postgres-in-containers), identity
(Kanidm + oauth2-proxy with the `forward_auth_kanidm` Caddyfile snippet),
the media stack (Jellyfin, Jellyseerr, Sonarr, Sonarr-Anime, Radarr,
Whisparr, Prowlarr, qBittorrent, Recyclarr; Pinchflat module is present
with `enable = false`), Paperless, and the monitoring stack (Prometheus,
node/zfs/smartctl exporters, Loki, Alloy, Grafana, Scrutiny). Each service
binds to `127.0.0.1`, fronted by Caddy on `<svc>.scheelite.dev`, gated
either by native OIDC (Kanidm-aware: Grafana, Paperless, future
Nextcloud/Immich) or by `forward_auth_kanidm` (everything else — except
AdGuard, which is *intended* to gate via its own admin login but currently
has `users: []` and is therefore unauthenticated; Phase 2 below fixes this).

What's missing is a **landing page** that aggregates the sprawl into one
URL. After comparing Heimdall (no nixpkgs package), Homarr (no nixpkgs
package and web-UI configured — fights our zero-clicks goal), Homer
(no live data widgets), Glance (no native widgets for the *arr / Jellyfin
ecosystem — would force us to hand-write Go templates per service), and
Homepage (`gethomepage/homepage`, packaged as `homepage-dashboard` 1.12.1
in nixpkgs), Homepage is the only candidate with a mature NixOS module
*and* native widgets covering the full stack.

Glances is added alongside Homepage to feed the resources widget with
richer system stats than the built-in `resources` widget can provide
(per-process CPU/mem, sensor temps, etc.) and to provide its own
host-stats UI on `glances.scheelite.dev`.

## Locked decisions

| Topic | Decision |
|---|---|
| Dashboard package | `homepage-dashboard` (gethomepage), upstream `services.homepage-dashboard` |
| Stats backend | `glances -w` running headless, exposed both to Homepage's `glances` widget on loopback and as its own UI vhost |
| Module path | `nixos-modules/services/homepage/module.nix` + `nixos-modules/services/glances/module.nix` |
| Domain | Homepage: `home.scheelite.dev` · Glances: `glances.scheelite.dev` |
| Auth | Both vhosts behind `forward_auth_kanidm` — same pattern as every other non-OIDC service |
| Bind | Homepage: all interfaces on port 8082 (firewall closed; Caddy proxies on loopback) · Glances: `127.0.0.1:61208` |
| `HOMEPAGE_ALLOWED_HOSTS` | Set to `home.scheelite.dev` — upstream defaults to `localhost:8082,127.0.0.1:8082` and rejects vhost-proxied traffic with 403 unless overridden |
| Secrets | Single `sops.templates."homepage.env"` with `HOMEPAGE_VAR_<SVC>_*=…` lines; mounted via `services.homepage-dashboard.environmentFiles`. No new sops secrets needed in v1 — all values are placeholders for existing keys |
| Substitution | `{{HOMEPAGE_VAR_X}}` (env-var inline). Verified in `src/utils/config/config.js:64-80` of upstream homepage |
| Layout | Auto-derived from each enabled `theonecfg.services.<svc>` module. Groups: Identity / Media / Documents / Networking / Monitoring |
| Top-level widgets | `resources` (CPU/memory + disk for `/`, `/tank0`, `/persist`) + `glances` (URL → loopback Glances) |
| Bookmarks | None this iteration |
| Impermanence | None added. Homepage runs `DynamicUser=true` with a `StateDirectory` that holds nothing in our declarative-only setup; CacheDirectory wiped each preStart by upstream module. Glances has no persistent state. Config lives in `/etc/homepage-dashboard/*.yaml` from the Nix store on every boot |
| Override mechanism | `theonecfg.services.homepage.{extraServices,extraWidgets}` — additive. Suppression of an auto-derived tile is out of scope (use `services.<svc>.enable = false` if you don't want a tile) |
| Widget gaps | Jellyfin only — link-only tile, needs a Jellyfin bootstrap extension (Phase 4, deferred). AdGuard / Jellyseerr / Grafana widgets ship in this plan: AdGuard via Phase 2 (new admin user + sops password), Jellyseerr + Grafana via Phase 3 (extraction unit + local-admin user respectively) |
| qBittorrent widget creds | Real `admin` + `qbittorrent/password` from sops. The `AuthSubnetWhitelist=127.0.0.1/32` we already set means homepage's loopback request never triggers login, but passing real creds removes a footgun if the bypass is ever tightened |

## Module layout

Auto-imported by the existing `nixos-modules/services/module.nix`
`getDirectoryNames` boilerplate — no manual wiring in a parent file.

```text
nixos-modules/services/
├── glances/module.nix       NEW — services.glances headless + Caddy vhost
└── homepage/module.nix      NEW — services.homepage-dashboard, auto-derived tiles + widgets
```

## Per-widget mapping

Single source of truth for what's a widgeted tile vs link-only in v1.
"Auth" describes what the upstream homepage widget requires; "v1 status"
records what we ship now.

| Service module | `theonecfg.services.<svc>` | Widget type | Auth required by widget | v1 status | Gap (if link-only) |
|---|---|---|---|---|---|
| Sonarr | `sonarr` | `sonarr` | API key | widget | — |
| Sonarr-Anime | `sonarr-anime` | `sonarr` | API key | widget | — |
| Radarr | `radarr` | `radarr` | API key | widget | — |
| Whisparr | `whisparr` | (none upstream) | — | link-only | Homepage has no Whisparr widget |
| Prowlarr | `prowlarr` | `prowlarr` | API key | widget | — |
| qBittorrent | `qbittorrent` | `qbittorrent` | username/password (loopback bypass means it's not exercised) | widget | — |
| Jellyfin | `jellyfin` | `jellyfin` | API key | link-only | sops has `jellyfin/admin-password` but not an API key — needs bootstrap extension (Phase 4, deferred) |
| Jellyseerr | `jellyseerr` | `jellyseerr` (alias for `seerr`) | API key | widget (Phase 3) | Phase 3 adds a follow-up unit that `jq`-extracts `main.apiKey` from `/var/lib/private/seerr/settings.json` after bootstrap, writes it to a root-readable file, referenced via `HOMEPAGE_FILE_JELLYSEERR_KEY` |
| Pinchflat | `pinchflat` | (none upstream) | — | link-only | Homepage has no Pinchflat widget |
| Paperless-ngx | `paperless` | `paperlessngx` | username + password (token also accepted) | widget | — |
| AdGuard Home | `adguard` | `adguard` | username/password | widget (Phase 2) | Phase 2 adds `users:` to AdGuard settings + new sops `adguard/admin-password` + ExecStartPre that bcrypts the plaintext into the mutable config. Closes the pre-existing security gap |
| Kanidm | `kanidm` | (none upstream) | — | link-only | Homepage has no Kanidm widget |
| Grafana | `monitoring.grafana` | `grafana` | basic auth (no OIDC support) | widget (Phase 3) | Phase 3 adds a local-admin user to `services.grafana.settings.security` alongside the existing OIDC; password from new sops `grafana/admin-password`. Humans still log in via Kanidm OIDC; only the Homepage widget uses the local creds |
| Prometheus | `monitoring.prometheus` | `prometheus` | none | widget | — |
| Scrutiny | `monitoring.scrutiny` | `scrutiny` | none | widget | — |

Verified against `/tmp/investigate/homepage/src/widgets/` (upstream
`gethomepage/homepage` `main`). Whisparr / Pinchflat / Kanidm have no
upstream widget directory.

## Glances module — sketch

Small enough to commit in full. Mirrors every other service in shape:

```nix
{ config, lib, ... }:
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) int str;
  cfg = config.theonecfg.services.glances;
in
{
  options.theonecfg.services.glances = {
    enable = mkEnableOption "Glances system metrics + REST API";
    domain = mkOption {
      type = str;
      default = "glances.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 61208;
      description = "Glances web/REST API port; bound to loopback. Caddy proxies from there.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.glances = {
        enable = true;
        port = cfg.port;
        # `-w` runs the web/REST API mode; `--bind 127.0.0.1` keeps it
        # off the LAN even if openFirewall ever flips on.
        extraArgs = [
          "-w"
          "--bind"
          "127.0.0.1"
        ];
      };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
```

No state. No sops. No impermanence entry.

## Homepage module — sketch

Auto-derives the service tile / widget list from the existing
`theonecfg.services.<svc>` modules — same pattern as
`nixos-modules/services/jellyseerr/module.nix:42-77` builds its
`arrInstances` list from enabled *arr modules.

```nix
{ config, lib, pkgs, ... }:
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) int listOf str;

  cfg = config.theonecfg.services.homepage;
  svc = config.theonecfg.services;

  # YAML 1.1 value type — same shape as `services.homepage-dashboard.{services,widgets}`
  # upstream uses, so user-supplied extras pass through cleanly.
  settingsFormat = pkgs.formats.yaml { };

  # Public URL helper. Each module's vhost is `<svc-domain>` over HTTPS
  # against the LAN domain — every existing service module exposes
  # `domain` as `<name>.${lanDomain}`.
  publicUrl = domain: "https://${domain}";

  # Each entry describes how to render one tile. `widget` may be null,
  # in which case the tile is a link-only card.
  knownTiles = [
    # --- Identity ---
    {
      enabled = svc.kanidm.enable;
      group = "Identity";
      name = "Kanidm";
      href = publicUrl svc.kanidm.domain;
      icon = "kanidm.svg";
      description = "Identity provider";
      widget = null;
    }

    # --- Media ---
    {
      enabled = svc.jellyfin.enable;
      group = "Media";
      name = "Jellyfin";
      href = publicUrl svc.jellyfin.domain;
      icon = "jellyfin.svg";
      description = "Media library";
      widget = null;  # Phase 3: API-key extraction
    }
    {
      enabled = svc.jellyseerr.enable;
      group = "Media";
      name = "Jellyseerr";
      href = publicUrl svc.jellyseerr.domain;
      icon = "jellyseerr.svg";
      description = "Media requests";
      widget = {
        type = "jellyseerr";
        url = "http://127.0.0.1:${toString svc.jellyseerr.port}";
        # Substituted from a file at runtime — see Phase 3's seerr-api-key
        # extraction one-shot, which writes the key Seerr generates on first
        # run to a stable root-readable path.
        key = "{{HOMEPAGE_FILE_JELLYSEERR_KEY}}";
      };
    }
    {
      enabled = svc.sonarr.enable;
      group = "Media";
      name = "Sonarr";
      href = publicUrl svc.sonarr.domain;
      icon = "sonarr.svg";
      description = "TV series";
      widget = {
        type = "sonarr";
        url = "http://127.0.0.1:${toString svc.sonarr.port}";
        key = "{{HOMEPAGE_VAR_SONARR_KEY}}";
        enableQueue = true;
      };
    }
    {
      enabled = svc.sonarr-anime.enable;
      group = "Media";
      name = "Sonarr (Anime)";
      href = publicUrl svc.sonarr-anime.domain;
      icon = "sonarr.svg";
      description = "Anime series";
      widget = {
        type = "sonarr";
        url = "http://127.0.0.1:${toString svc.sonarr-anime.port}";
        key = "{{HOMEPAGE_VAR_SONARR_ANIME_KEY}}";
        enableQueue = true;
      };
    }
    {
      enabled = svc.radarr.enable;
      group = "Media";
      name = "Radarr";
      href = publicUrl svc.radarr.domain;
      icon = "radarr.svg";
      description = "Movies";
      widget = {
        type = "radarr";
        url = "http://127.0.0.1:${toString svc.radarr.port}";
        key = "{{HOMEPAGE_VAR_RADARR_KEY}}";
        enableQueue = true;
      };
    }
    {
      enabled = svc.whisparr.enable;
      group = "Media";
      name = "Whisparr";
      href = publicUrl svc.whisparr.domain;
      icon = "whisparr.svg";
      description = "Adult";
      widget = null;  # No upstream widget
    }
    {
      enabled = svc.prowlarr.enable;
      group = "Media";
      name = "Prowlarr";
      href = publicUrl svc.prowlarr.domain;
      icon = "prowlarr.svg";
      description = "Indexer manager";
      widget = {
        type = "prowlarr";
        url = "http://127.0.0.1:${toString svc.prowlarr.port}";
        key = "{{HOMEPAGE_VAR_PROWLARR_KEY}}";
      };
    }
    {
      enabled = svc.qbittorrent.enable;
      group = "Media";
      name = "qBittorrent";
      href = publicUrl svc.qbittorrent.domain;
      icon = "qbittorrent.svg";
      description = "BitTorrent client";
      widget = {
        type = "qbittorrent";
        url = "http://127.0.0.1:${toString svc.qbittorrent.webUiPort}";
        username = "{{HOMEPAGE_VAR_QBT_USERNAME}}";
        password = "{{HOMEPAGE_VAR_QBT_PASSWORD}}";
      };
    }
    {
      enabled = svc.pinchflat.enable;
      group = "Media";
      name = "Pinchflat";
      href = publicUrl svc.pinchflat.domain;
      icon = "pinchflat.svg";
      description = "YouTube archiver";
      widget = null;  # No upstream widget
    }

    # --- Documents ---
    {
      enabled = svc.paperless.enable;
      group = "Documents";
      name = "Paperless-ngx";
      href = publicUrl svc.paperless.domain;
      icon = "paperless-ngx.svg";
      description = "Document archive";
      widget = {
        type = "paperlessngx";
        url = "http://127.0.0.1:${toString svc.paperless.port}";
        username = "{{HOMEPAGE_VAR_PAPERLESS_USERNAME}}";
        password = "{{HOMEPAGE_VAR_PAPERLESS_PASSWORD}}";
      };
    }

    # --- Networking ---
    {
      enabled = svc.adguard.enable;
      group = "Networking";
      name = "AdGuard Home";
      href = publicUrl svc.adguard.domain;
      icon = "adguard-home.svg";
      description = "DNS + ad blocking";
      widget = {
        type = "adguard";
        url = "http://127.0.0.1:${toString svc.adguard.port}";
        username = "{{HOMEPAGE_VAR_ADGUARD_USERNAME}}";
        password = "{{HOMEPAGE_VAR_ADGUARD_PASSWORD}}";
      };
    }

    # --- Monitoring ---
    {
      enabled = svc.monitoring.grafana.enable;
      group = "Monitoring";
      name = "Grafana";
      href = publicUrl svc.monitoring.grafana.domain;
      icon = "grafana.svg";
      description = "Dashboards";
      widget = {
        type = "grafana";
        # Loopback — widget calls Grafana's HTTP API directly, bypassing
        # Caddy. The local-admin user added in Phase 3 has its credential
        # injected via the env file. Humans continue to log in via Kanidm
        # OIDC at the public URL.
        url = "http://127.0.0.1:${toString svc.monitoring.grafana.port}";
        username = "{{HOMEPAGE_VAR_GRAFANA_USERNAME}}";
        password = "{{HOMEPAGE_VAR_GRAFANA_PASSWORD}}";
      };
    }
    {
      enabled = svc.monitoring.prometheus.enable;
      group = "Monitoring";
      name = "Prometheus";
      href = "http://127.0.0.1:${toString svc.monitoring.prometheus.port}";
      icon = "prometheus.svg";
      description = "Metrics";
      widget = {
        type = "prometheus";
        url = "http://127.0.0.1:${toString svc.monitoring.prometheus.port}";
      };
    }
    {
      enabled = svc.monitoring.scrutiny.enable;
      group = "Monitoring";
      name = "Scrutiny";
      href = publicUrl svc.monitoring.scrutiny.domain;
      icon = "scrutiny.svg";
      description = "SMART monitoring";
      widget = {
        type = "scrutiny";
        url = "http://127.0.0.1:${toString svc.monitoring.scrutiny.port}";
      };
    }
  ];

  enabledTiles = lib.filter (t: t.enabled) knownTiles;

  groupOrder = [
    "Identity"
    "Media"
    "Documents"
    "Networking"
    "Monitoring"
  ];

  # Group enabledTiles by `.group`, preserving groupOrder. Each group
  # is a single-key attrset whose value is a list of single-key
  # attrsets (homepage's services.yaml schema).
  servicesYaml = map (groupName: {
    ${groupName} = map (tile: {
      ${tile.name} =
        {
          inherit (tile) href icon description;
        }
        // lib.optionalAttrs (tile.widget != null) { inherit (tile) widget; };
    }) (lib.filter (t: t.group == groupName) enabledTiles);
  }) (lib.filter (g: lib.any (t: t.group == g) enabledTiles) groupOrder);

  # Top-level "info" widgets — independent of services.yaml.
  infoWidgets =
    [
      {
        resources = {
          cpu = true;
          memory = true;
          disk = [
            "/"
            "/tank0"
            "/persist"
          ];
        };
      }
    ]
    ++ lib.optional svc.glances.enable {
      glances = {
        url = "http://127.0.0.1:${toString svc.glances.port}";
        version = 4;
        chart = false;
      };
    };

in
{
  options.theonecfg.services.homepage = {
    enable = mkEnableOption "Homepage dashboard";
    domain = mkOption {
      type = str;
      default = "home.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 8082;
      description = "Homepage listen port. Caddy proxies from this on loopback.";
    };
    extraServices = mkOption {
      type = listOf settingsFormat.type;
      default = [ ];
      description = "Additional services.yaml groups appended to the auto-derived list.";
    };
    extraWidgets = mkOption {
      type = listOf settingsFormat.type;
      default = [ ];
      description = "Additional top-level widgets (e.g. search, datetime) appended to resources + glances.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.homepage-dashboard = {
        enable = true;
        listenPort = cfg.port;
        # Upstream default is `localhost:8082,127.0.0.1:8082` — proxied
        # vhost requests get rejected with 403 unless this matches the
        # public hostname. CSV-style, no scheme. Include both the public
        # domain (for Caddy-proxied browser access) and loopback (so
        # debug curls and any future local healthchecks against
        # 127.0.0.1:port don't trip the Host-header check).
        allowedHosts = "${cfg.domain},localhost:${toString cfg.port},127.0.0.1:${toString cfg.port}";
        environmentFiles = [ config.sops.templates."homepage.env".path ];
        services = servicesYaml ++ cfg.extraServices;
        widgets = infoWidgets ++ cfg.extraWidgets;
        settings = {
          title = "scheelite";
          # Stick to a single page; layout key reorders/styles groups.
          # Use defaults — drop in custom CSS later if desired.
        };
      };

      sops.templates."homepage.env" = {
        # No `owner =` — sops defaults to root:root mode 0440. systemd
        # reads EnvironmentFile= as PID 1 before dropping privileges to
        # the DynamicUser, so root-owned is fine and avoids the
        # DynamicUser-with-static-owner fragility.
        content = ''
          HOMEPAGE_VAR_SONARR_KEY=${config.sops.placeholder."sonarr/api-key"}
          HOMEPAGE_VAR_SONARR_ANIME_KEY=${config.sops.placeholder."sonarr-anime/api-key"}
          HOMEPAGE_VAR_RADARR_KEY=${config.sops.placeholder."radarr/api-key"}
          HOMEPAGE_VAR_PROWLARR_KEY=${config.sops.placeholder."prowlarr/api-key"}
          HOMEPAGE_VAR_QBT_USERNAME=admin
          HOMEPAGE_VAR_QBT_PASSWORD=${config.sops.placeholder."qbittorrent/password"}
          HOMEPAGE_VAR_PAPERLESS_USERNAME=admin
          HOMEPAGE_VAR_PAPERLESS_PASSWORD=${config.sops.placeholder."paperless/admin-password"}
          HOMEPAGE_VAR_ADGUARD_USERNAME=admin
          HOMEPAGE_VAR_ADGUARD_PASSWORD=${config.sops.placeholder."adguard/admin-password"}
          # HOMEPAGE_FILE_* — homepage reads the file at this path and
          # substitutes its contents. Phase 3's jellyseerr-api-key.service
          # writes the file.
          HOMEPAGE_FILE_JELLYSEERR_KEY=/var/lib/seerr/api-key.txt
          HOMEPAGE_VAR_GRAFANA_USERNAME=admin
          HOMEPAGE_VAR_GRAFANA_PASSWORD=${config.sops.placeholder."grafana/admin-password"}
        '';
      };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
```

### Notes on the sketch

- **`servicesYaml` shape**: upstream `services.homepage-dashboard.services`
  takes a list of single-key attrsets, each value being a list of
  single-key attrsets. Verified in
  `nixos/modules/services/misc/homepage-dashboard.nix:131-152` (example
  attribute). This shape is directly serialized by `pkgs.formats.yaml`.
- **Substitution**: homepage's `substituteEnvironmentVars` (in
  `src/utils/config/config.js:64-80`) replaces `{{HOMEPAGE_VAR_X}}` /
  `{{HOMEPAGE_FILE_X}}` placeholders in any of `services.yaml`,
  `widgets.yaml`, etc. at runtime. Our YAML therefore embeds those
  placeholders, and the sops template populates the env vars.
- **Widget `url` is loopback**: each widget's `url` field points at
  `http://127.0.0.1:<port>`, NOT the public `https://<svc>.scheelite.dev`.
  Going through the public URL would re-enter Caddy → forward-auth →
  oauth2-proxy redirect → 401 (no session for an internal service).
  Loopback skips that entirely.
- **`href` is the public URL**: the click-through target for users.
  These DO go through Caddy + forward-auth, so the user logs in once
  via Kanidm and follows the per-service link normally.
- **`extraServices` / `extraWidgets`**: additive only. Suppressing an
  auto-derived tile means disabling the underlying service module. If
  per-tile suppression becomes a real need, add a follow-up option
  rather than retrofitting filtering into v1.

## Sops template content

Single template, mounted via `services.homepage-dashboard.environmentFiles`.
Mix of `HOMEPAGE_VAR_*` (env-var value substituted in) and `HOMEPAGE_FILE_*`
(env var holds a path, homepage reads file contents at substitution time).

```text
HOMEPAGE_VAR_SONARR_KEY=${...sonarr/api-key placeholder}
HOMEPAGE_VAR_SONARR_ANIME_KEY=${...sonarr-anime/api-key placeholder}
HOMEPAGE_VAR_RADARR_KEY=${...radarr/api-key placeholder}
HOMEPAGE_VAR_PROWLARR_KEY=${...prowlarr/api-key placeholder}
HOMEPAGE_VAR_QBT_USERNAME=admin
HOMEPAGE_VAR_QBT_PASSWORD=${...qbittorrent/password placeholder}
HOMEPAGE_VAR_PAPERLESS_USERNAME=admin
HOMEPAGE_VAR_PAPERLESS_PASSWORD=${...paperless/admin-password placeholder}
HOMEPAGE_VAR_ADGUARD_USERNAME=admin
HOMEPAGE_VAR_ADGUARD_PASSWORD=${...adguard/admin-password placeholder}
HOMEPAGE_FILE_JELLYSEERR_KEY=/var/lib/seerr/api-key.txt
HOMEPAGE_VAR_GRAFANA_USERNAME=admin
HOMEPAGE_VAR_GRAFANA_PASSWORD=${...grafana/admin-password placeholder}
```

`admin` is qBittorrent's and Paperless's default first-user username;
neither module overrides it. AdGuard and Grafana admin users are
created with `admin` username by Phase 2 and Phase 3 respectively.

### New sops secrets introduced

Three new keys added to `secrets/scheelite.yaml` over the course of
this plan. All can be regenerated by re-running
`bootstrap-homelab-secrets`; v1 of that script needs new entries for
each (parallel to existing `kanidm/oauth-grafana`, etc.):

- `adguard/admin-password` — plaintext, bcrypt'd at runtime by Phase 2's
  ExecStartPre. Used by AdGuard's `users:` config and the Homepage
  AdGuard widget.
- `grafana/admin-password` — plaintext, read by Grafana via `$__file{}`
  for the local-admin user added in Phase 3. Same pattern as the
  existing `grafana/secret-key`.

Plus one runtime-derived file (no sops entry):

- `/var/lib/seerr/api-key.txt` — written by Phase 3's
  `jellyseerr-api-key.service` after `jellyseerr-bootstrap` completes.

### Trailing-newline caveat

`sops.placeholder` substitutes the secret value verbatim. Some entries
in `secrets/scheelite.yaml` were created with `echo "value"` and carry
trailing newlines. systemd's EnvironmentFile= parser treats a newline
as the line terminator, so a `KEY=value\n` line works correctly and
the trailing newline is consumed. If a secret somehow contains an
embedded newline mid-value, parsing breaks — verify each rendered env
file with `cat /run/secrets/<...>` after `nixos-rebuild test` and
re-create offending secrets without `echo`'s `-n`.

## Scheelite wiring

`nixos-configurations/scheelite/default.nix` `theonecfg.services` block
gains:

```nix
glances.enable = true;
homepage.enable = true;
```

That's the entire config-side change. The Homepage module's defaults
auto-derive every tile from the existing `theonecfg.services.<svc>`
modules already enabled in scheelite.

## Phased rollout

Each phase ends with a clean
`nix build .#nixosConfigurations.scheelite.config.system.build.toplevel`.

### Phase 1 — Glances module + vhost

**Files:**

- Create `nixos-modules/services/glances/module.nix` — full body in the
  Glances sketch above.
- `nixos-configurations/scheelite/default.nix`: add
  `glances.enable = true;` to the `theonecfg.services` block.

**Verify (post-deploy):**

- `systemctl status glances` — active, no errors.
- `curl -fsS http://127.0.0.1:61208/api/4/cpu | jq` returns CPU
  metrics (non-empty `total`).
- `curl -fsSI https://glances.scheelite.dev/` — 302 redirect to
  Kanidm login (forward-auth gate active).
- After login: browser shows the Glances UI on
  `https://glances.scheelite.dev/`.
- `nix flake check` — clean.

**Why this lands first**: Homepage's `glances` widget points at the
loopback Glances API. If Glances isn't already up when Homepage starts,
the widget renders an error state on first paint until Glances comes
online. Sequencing them isolates failure.

### Phase 2 — AdGuard auth gap fix

Standalone security fix. AdGuard's UI is currently exposed without
authentication via the Caddy vhost, because the module's comment
("AdGuard has its own admin login") was never paired with a `users:`
config. Verified pre-fix: `GET /control/status` returns 200 with
`{"version":"...","dns_addresses":[...]}` — full unauthenticated
admin API. This phase fixes that, and as a side effect supplies the
credentials the Phase 3 Homepage AdGuard widget will use.

**Files:**

- Modify `nixos-modules/services/adguard/module.nix`:
  - Declare `services.adguardhome.settings.users = [ { name = "admin"; password = "ADGUARD_PASSWORD_PLACEHOLDER"; } ];`. With `mutableSettings = false`, the upstream module will install this on every restart.
  - Add an ExecStartPre script (mirrors `qbtPasswordHashScript` in
    `library/declarative-arr.nix:832-887` but emits bcrypt instead of
    PBKDF2). Reads `/run/secrets/adguard/admin-password`, bcrypt-hashes
    it (e.g. via `mkpasswd -m bcrypt`), and replaces the placeholder
    in `/var/lib/private/AdGuardHome/AdGuardHome.yaml` with the hash.
    Use `yq` rather than sed — multi-line YAML edits with sed are
    fragile.
  - Add `sops.secrets."adguard/admin-password"` (owner depends on the
    user the AdGuard service runs as — `services.adguardhome` uses
    `DynamicUser=true`, so root-owned mode 0440 with the ExecStartPre
    running as root is fine).
- `secrets/scheelite.yaml`: add `adguard.admin-password` (run via the
  bootstrap script or `sops` editor for an existing host).
- `package-sets/top-level/theonecfg/bootstrap-homelab-secrets/bootstrap.sh`:
  add `adguard.admin-password: $(gen_password)` in the scheelite
  template.

**Verify (post-deploy):**

- `getent group adguard` is unrelated; AdGuard runs as a DynamicUser.
- `sudo cat /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -A2 '^users:'`
  shows one entry with `name: admin` and a `password: $2a$...` (or
  similar bcrypt prefix) — not the placeholder.
- `curl -sk -o /dev/null -w "%{http_code}\n" https://adguard.scheelite.dev/control/status`
  now returns `401` (was `200` pre-fix).
- `curl -sk -u admin:<plaintext> https://adguard.scheelite.dev/control/status`
  returns 200 with the real status JSON.
- Browser: visiting `https://adguard.scheelite.dev/` now shows
  AdGuard's login form. Logging in as `admin` with the plaintext
  password from sops grants access.

**Why this lands before Phase 3**: closing the open access is its
own win, separable from Homepage. If Phase 3 hits an unrelated
problem and rolls back, AdGuard stays secured.

### Phase 3 — Homepage module + Jellyseerr/Grafana prep

Bundles three changes that compose into a single working dashboard:

1. Jellyseerr API-key extraction follow-up (so the Jellyseerr widget has a key to use).
2. Grafana local-admin user (so the Grafana widget can authenticate).
3. Homepage module itself + scheelite wiring.

**Files:**

- Modify `nixos-modules/services/jellyseerr/module.nix`:
  - Add a new oneshot `jellyseerr-api-key.service` ordered `after = [
    "jellyseerr-bootstrap.service" ]` and `requires`. Reads
    `/var/lib/private/seerr/settings.json` (Seerr's DynamicUser
    private state), `jq -r '.main.apiKey'` from it, writes to
    `/var/lib/seerr/api-key.txt` mode 0440 root:root via `install
    -m`. Idempotent: re-runs are no-ops if the file is up to date.
- Modify `nixos-modules/services/monitoring/grafana/module.nix`:
  - In the `mkIf cfg.enable` block, add `services.grafana.settings.security.admin_user = "admin";`
    and `admin_password = "$__file{${config.sops.secrets."grafana/admin-password".path}}";`
    alongside the existing `secret_key`.
  - Add `sops.secrets."grafana/admin-password".owner = "grafana";`.
  - Note: the OIDC config stays untouched — humans still log in via
    Kanidm; only the Homepage widget uses the local admin.
- `secrets/scheelite.yaml`: add `grafana.admin-password`.
- `package-sets/top-level/theonecfg/bootstrap-homelab-secrets/bootstrap.sh`:
  add `grafana.admin-password: $(gen_password)`.
- Create `nixos-modules/services/homepage/module.nix` — full body per
  the Homepage sketch above.
- `nixos-configurations/scheelite/default.nix`: add `homepage.enable = true;`.

**Pre-deploy local checks:**

- `nix flake check` — clean.
- `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel`
  — closes without error.
- `nix eval .#nixosConfigurations.scheelite.config.services.homepage-dashboard.services --json | jq`
  — auto-derived services list looks correct; each enabled service has
  a tile and the widget config has the right port and the correct
  `{{HOMEPAGE_*_*}}` placeholders.

**Verify (post-deploy):**

- `systemctl status homepage-dashboard jellyseerr-api-key` — both
  active. `ProcSubset=all` is expected since we set `cpu = true` on
  the resources widget (upstream homepage module relaxes ProcSubset
  when CPU stats are needed).
- `sudo cat /var/lib/seerr/api-key.txt` — non-empty 32-char-ish
  string, matches `jq -r .main.apiKey
  /var/lib/private/seerr/settings.json`.
- `curl -fsS -H "Host: home.scheelite.dev" http://127.0.0.1:8082/`
  — 200 with HTML containing "scheelite" (title) and group names.
- `curl -fsSI https://home.scheelite.dev/` — 302 to Kanidm.
- After login: dashboard renders. Per-widget live data:
  - **Widgeted**: Sonarr (×2), Radarr, Prowlarr, qBittorrent,
    Paperless, Prometheus, Scrutiny, AdGuard, Jellyseerr, Grafana.
  - **Link-only**: Whisparr, Pinchflat (off), Jellyfin, Kanidm.
- `journalctl -u homepage-dashboard -b 0 | rg -i "error|warn"` —
  clean. Most failure modes show as widget-side errors (HTTP 401/403
  from a misconfigured credential).

**Common failure modes to watch for:**

- `403 Forbidden` with `Disallowed host`: request `Host:` doesn't
  match `allowedHosts`. We widened to include loopback already, but
  any non-matching Host (curl with explicit `-H 'Host: foo'`) trips
  this. Caddy preserves the original Host header by default.
- Widget shows "Error fetching data": almost always an
  unsubstituted `{{HOMEPAGE_*_*}}` or wrong creds. Check
  `journalctl -u homepage-dashboard | rg <widget-type>` — homepage
  logs the upstream HTTP status on widget fetches.
- Jellyseerr widget shows nothing: `cat
  /var/lib/seerr/api-key.txt` should be readable by root (the env
  file is read by systemd as PID 1 before DynamicUser drop). If
  empty, `jellyseerr-api-key` likely ran before Seerr finished
  generating its settings.
- Grafana widget shows 401: confirm `admin` exists in Grafana —
  visit `https://grafana.scheelite.dev/admin/users` (after Kanidm
  login) and verify the local user is present.
- Resources widget shows wrong disk: homepage's `resources.disk`
  takes a list of mount points; verify with
  `findmnt /` / `findmnt /tank0` / `findmnt /persist`.

### Phase 4 — DEFERRED — Jellyfin widget

Out of scope this plan. Documented so it isn't lost when scope
expands.

Extend `nixos-modules/services/jellyfin/module.nix`'s bootstrap unit
(or add a follow-up post-bootstrap unit) to obtain a Jellyfin API
key and persist it to a root-readable file. Two paths:

- (a) Call `/Users/AuthenticateByName` with the admin user; capture
  the returned `AccessToken`. Token validity is the active session,
  so the file needs refresh on session expiry — fragile.
- (b) After auth, call the admin `/api-keys` endpoint to *create* a
  permanent API key. Token survives sessions. Recommended.

Reference the path via `HOMEPAGE_FILE_JELLYFIN_KEY=/var/lib/jellyfin/api-key.txt`
in the Homepage env template; flip the Jellyfin tile in `knownTiles`
from `widget = null` to the populated `jellyfin` widget config.

When this lands, update this plan's per-widget mapping table from
`link-only` to `widget` and remove this section.

## Critical files

To create:

- `nixos-modules/services/glances/module.nix` (Phase 1)
- `nixos-modules/services/homepage/module.nix` (Phase 3)

To modify:

- `nixos-modules/services/adguard/module.nix` (Phase 2) — add `users:`
  with placeholder, ExecStartPre to bcrypt + inject, sops secret.
- `nixos-modules/services/jellyseerr/module.nix` (Phase 3) — new
  `jellyseerr-api-key.service` follow-up oneshot.
- `nixos-modules/services/monitoring/grafana/module.nix` (Phase 3) —
  add local-admin user, sops secret read via `$__file{}`.
- `nixos-configurations/scheelite/default.nix` (Phases 1, 3) — add
  `glances.enable` and `homepage.enable` to the `theonecfg.services`
  block.
- `secrets/scheelite.yaml` (Phases 2, 3) — add
  `adguard/admin-password` and `grafana/admin-password`.
- `package-sets/top-level/theonecfg/bootstrap-homelab-secrets/bootstrap.sh`
  (Phases 2, 3) — generate the two new entries for fresh hosts.

Not touched:

- `nixos-configurations/scheelite/impermanence.nix` — no new persistence
  entries (homepage state is ephemeral; glances has none; the
  jellyseerr api-key file lives at `/var/lib/seerr/api-key.txt`,
  re-derived on every boot from the persisted Seerr DB).
- `flake.nix` — no new inputs; both packages already in nixpkgs.
- `nixos-modules/services/module.nix` — auto-import handles new dirs.

## Reused functions / patterns

- `library/default.nix` `getDirectoryNames` / auto-import via
  `nixos-modules/services/module.nix:19-25` — picks up `glances/` and
  `homepage/` automatically.
- `home-modules/programs/fish/module.nix:1-29` — `mkEnableOption` +
  `config = mkIf cfg.enable` skeleton template.
- `nixos-modules/services/jellyseerr/module.nix:42-77` — pattern for
  walking enabled `theonecfg.services.<svc>` modules to build a
  derived list.
- `nixos-modules/services/caddy/module.nix:91-106` — sops-template +
  `EnvironmentFile=` pattern (for `homepage.env`).
- `nixos-modules/services/oauth2-proxy/module.nix:117-146` — Caddyfile
  `forward_auth_kanidm` snippet definition; per-vhost import via
  `import forward_auth_kanidm`.
- Each existing service module's `domain` / `port` options — read
  directly from `config.theonecfg.services.<svc>` to populate the
  Homepage tile list.

## Verification (whole plan)

- `nix fmt` — passes treefmt.
- `nix flake check` — clean (test-vm error pre-existing per
  `scheelite-homelab-services.md`).
- `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel`
  — closes.
- `nix eval .#nixosConfigurations.scheelite.config.services.homepage-dashboard.services --json | jq` —
  auto-derived list looks correct.
- After all three phases deployed:
  - `systemctl status glances homepage-dashboard jellyseerr-api-key` — all active.
  - `journalctl -u glances -u homepage-dashboard -u jellyseerr-api-key -b 0 | rg -i "error|warn"` — clean.
  - `curl -sk -o /dev/null -w "%{http_code}\n" https://adguard.scheelite.dev/control/status`
    — 401 (was 200 pre-Phase-2).
  - `cat /var/lib/seerr/api-key.txt` — non-empty.
  - `curl -fsS https://home.scheelite.dev/` after Kanidm login — 200, HTML.
  - `curl -fsS https://glances.scheelite.dev/` after Kanidm login — 200, HTML.
  - Browser smoke test: every enabled service has a tile in the
    expected group; every widgeted tile (Sonarr/Radarr/Prowlarr/qBt/
    Paperless/Prometheus/Scrutiny/AdGuard/Jellyseerr/Grafana) shows
    live data within ~10s; every link-only tile click-through reaches
    its target service behind Kanidm SSO.

## Out of scope this iteration

- **Jellyfin widget** (Phase 4 above). The other three previously-deferred
  widgets (Jellyseerr, AdGuard, Grafana) are now in scope via Phases 2
  and 3.
- **Bookmarks**. Trivial to add later via
  `services.homepage-dashboard.bookmarks` — defer until a concrete
  list emerges.
- **Custom CSS / branding / icons**. Upstream `customCSS` and
  `customJS` options exist; not exercising them this round.
- **Mobile-specific layout**. Homepage's responsive layout is
  acceptable out of the box.
- **Docker / Kubernetes / Proxmox provider integration.** None of
  these are in the homelab.
- **External (off-LAN) access** to `home.scheelite.dev`. Same rule
  as the rest of the stack — gated on the external-access decision
  in `scheelite-external-access-options.md`.
- **Pinchflat / Whisparr / Kanidm widgets.** No upstream widgets;
  link-only is permanent unless an upstream widget appears.
- **Per-tile suppression option** on the Homepage module (`.disable`
  or similar). YAGNI for v1 — disable the underlying service if you
  don't want a tile.
