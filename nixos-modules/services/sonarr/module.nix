{
  config,
  lib,
  pkgs,
  theonecfg,
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
    bool
    int
    listOf
    str
    ;

  cfg = config.theonecfg.services.sonarr;
  declarative = theonecfg.library.declarative pkgs;
  arrTypes = theonecfg.library.arrTypes;
  pgInstance = config.theonecfg.services.postgres.instances.sonarr;
  qbtCfg = config.theonecfg.services.qbittorrent;

  autoDownloadClients = lib.optional (cfg.autoQbittorrent && qbtCfg.enable) (
    declarative.mkQbtDownloadClient {
      port = qbtCfg.webUiPort;
      category = "sonarr";
    }
  );
  effectiveDownloadClients = autoDownloadClients ++ cfg.downloadClients;

in
{
  options.theonecfg.services.sonarr = {
    enable = mkEnableOption "Sonarr (TV show manager)";
    domain = mkOption {
      type = str;
      default = "sonarr.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 8989;
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/sonarr";
    };
    dbPort = mkOption {
      type = int;
      default = 5436;
      description = "Host port that forwards into the Sonarr postgres container.";
    };
    rootFolders = mkOption {
      type = listOf arrTypes.rootFolderType;
      default = [ ];
      example = [ { path = "/tank0/media/tv"; } ];
      description = "Declarative root folders. Reconciled via /api/v3/rootfolder on every activation.";
    };
    autoQbittorrent = mkOption {
      type = bool;
      default = true;
      description = ''
        Auto-add a qBittorrent download-client entry pointing at
        ``theonecfg.services.qbittorrent`` (category = "sonarr") whenever
        both modules are enabled. Disable to manage download clients
        entirely via ``downloadClients``.
      '';
    };
    downloadClients = mkOption {
      type = listOf arrTypes.downloadClientType;
      default = [ ];
      description = ''
        Manual download client entries. Merged with the auto-derived
        qBittorrent entry (when ``autoQbittorrent = true``) and reconciled
        via /api/v3/downloadclient.
      '';
    };
    delayProfiles = mkOption {
      type = listOf arrTypes.delayProfileType;
      default = [ ];
      description = "Declarative delay profiles. Reconciled via /api/v3/delayprofile.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.sonarr = {
        enable = true;
        dataDir = cfg.dataDir;
        # Env file for secrets (API key + postgres password). Assembled by
        # sops.templates from individual sops secrets, so we have a single
        # source of truth for the API key.
        environmentFiles = [ config.sops.templates."sonarr.env".path ];
        # Non-secret config goes via settings, which upstream auto-converts
        # to SONARR__<SECTION>__<KEY> env vars.
        settings = {
          server = {
            port = cfg.port;
            bindaddress = "127.0.0.1";
          };
          auth = {
            method = "Forms";
            required = "DisabledForLocalAddresses";
          };
          postgres = {
            host = pgInstance.host;
            port = pgInstance.containerPort;
            user = "sonarr";
            mainDb = "sonarr-main";
            logDb = "sonarr-log";
          };
          log.analyticsEnabled = false;
        };
      };

      users.users.sonarr.extraGroups = [ "media" ];

      sops.secrets = {
        "sonarr/api-key".owner = "sonarr";
        "sonarr/postgres-password".owner = "sonarr";
      };

      sops.templates."sonarr.env" = {
        content = ''
          SONARR__AUTH__APIKEY=${config.sops.placeholder."sonarr/api-key"}
          SONARR__POSTGRES__PASSWORD=${config.sops.placeholder."sonarr/postgres-password"}
        '';
        owner = "sonarr";
      };

      # Upstream sonarr's StateDirectory only kicks in for the default
      # /var/lib/sonarr/.config/NzbDrone path; with our override we create
      # dataDir ourselves. Each rootFolder is sgid 2775 owned by sonarr:media
      # so *arr/qbittorrent/jellyfin cross-access works (see media-storage).
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${toString config.ids.uids.sonarr} ${toString config.ids.gids.sonarr} - -"
      ]
      ++ map (r: "d ${r.path} 2775 sonarr media - -") cfg.rootFolders;

      # Wait for media root mounts before starting (upstream already adds
      # cfg.dataDir; we extend with the configured root folders).
      systemd.services.sonarr.unitConfig.RequiresMountsFor = map (r: r.path) cfg.rootFolders;

      # Per-service postgres instance — main + log databases, owner sonarr.
      theonecfg.services.postgres.instances.sonarr = {
        version = "16";
        port = cfg.dbPort;
        databases = [
          "sonarr-main"
          "sonarr-log"
        ];
        owner = "sonarr";
      };
    }

    (mkIf (cfg.rootFolders != [ ]) (
      declarative.mkArrApiPushService {
        name = "sonarr-rootfolders";
        after = [ "sonarr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."sonarr/api-key".path;
        endpoint = "/api/v3/rootfolder";
        items = cfg.rootFolders;
        comparator = "path";
        noUpdate = true;
      }
    ))

    (mkIf (effectiveDownloadClients != [ ]) (
      declarative.mkArrApiPushService {
        name = "sonarr-downloadclients";
        after = [ "sonarr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."sonarr/api-key".path;
        endpoint = "/api/v3/downloadclient";
        items = effectiveDownloadClients;
      }
    ))

    (mkIf (cfg.delayProfiles != [ ]) (
      declarative.mkArrApiPushService {
        name = "sonarr-delayprofiles";
        after = [ "sonarr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."sonarr/api-key".path;
        endpoint = "/api/v3/delayprofile";
        items = cfg.delayProfiles;
        # delayprofile uses tags as the comparator (no name field)
        comparator = "id";
      }
    ))

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
