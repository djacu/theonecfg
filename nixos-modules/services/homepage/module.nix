{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    mkMerge
    ;

  inherit (lib.options)
    mkEnableOption
    mkOption
    ;

  inherit (lib.types)
    int
    listOf
    str
    ;

  cfg = config.theonecfg.services.homepage;
  svc = config.theonecfg.services;

  # YAML 1.1 value type — same shape as services.homepage-dashboard's
  # upstream `services` and `widgets` options use, so user-supplied
  # extras pass through cleanly.
  settingsFormat = pkgs.formats.yaml { };

  publicUrl = domain: "https://${domain}";

  # Each entry is one tile. `widget` may be null for link-only cards
  # (services that have no upstream Homepage widget, or where credential
  # provisioning is deferred).
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
      widget = null; # Phase 4 (deferred): API-key extraction
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
      widget = null; # No upstream Homepage widget for Whisparr
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
      widget = null; # No upstream Homepage widget for Pinchflat
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
        # Loopback rather than the public Caddy URL — the widget calls
        # Grafana's HTTP API directly using basic auth, bypassing Caddy
        # and the OIDC flow. Humans still log in via Kanidm at the
        # public URL.
        url = "http://127.0.0.1:${toString svc.monitoring.grafana.port}";
        username = "{{HOMEPAGE_VAR_GRAFANA_USERNAME}}";
        password = "{{HOMEPAGE_VAR_GRAFANA_PASSWORD}}";
      };
    }
    {
      enabled = svc.monitoring.prometheus.enable;
      group = "Monitoring";
      name = "Prometheus";
      href = publicUrl svc.monitoring.prometheus.domain;
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

  # Group enabledTiles by .group, preserving groupOrder. Each group is
  # a single-key attrset whose value is a list of single-key attrsets
  # (homepage's services.yaml schema).
  servicesYaml = map (groupName: {
    ${groupName} = map (tile: {
      ${tile.name} =
        {
          inherit (tile) href icon description;
        }
        // lib.optionalAttrs (tile.widget != null) { inherit (tile) widget; };
    }) (lib.filter (t: t.group == groupName) enabledTiles);
  }) (lib.filter (g: lib.any (t: t.group == g) enabledTiles) groupOrder);

  # Top-level "info" widgets — independent of the services list.
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
        # public hostname. CSV-style, no scheme. Include both the
        # public domain (for Caddy-proxied browser access) and loopback
        # (so debug curls against 127.0.0.1:port don't trip the
        # Host-header check).
        allowedHosts = "${cfg.domain},localhost:${toString cfg.port},127.0.0.1:${toString cfg.port}";
        environmentFiles = [ config.sops.templates."homepage.env".path ];
        services = servicesYaml ++ cfg.extraServices;
        widgets = infoWidgets ++ cfg.extraWidgets;
        settings = {
          title = "scheelite";
        };
      };

      sops.templates."homepage.env" = {
        # No `owner =` — sops defaults to root:root mode 0400.
        # services.homepage-dashboard.environmentFiles is read by
        # systemd as PID 1 before dropping privileges to the
        # DynamicUser, so root-owned is fine.
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
          HOMEPAGE_FILE_JELLYSEERR_KEY=/run/jellyseerr/api-key.txt
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
