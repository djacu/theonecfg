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
    int
    listOf
    str
    ;

  cfg = config.theonecfg.services.radarr;
  declarative = theonecfg.library.declarative pkgs;
  arrTypes = theonecfg.library.arrTypes;
  pgInstance = config.theonecfg.services.postgres.instances.radarr;

in
{
  options.theonecfg.services.radarr = {
    enable = mkEnableOption "Radarr (movie manager)";
    domain = mkOption {
      type = str;
      default = "radarr.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 7878;
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/radarr";
    };
    dbPort = mkOption {
      type = int;
      default = 5438;
      description = "Host port that forwards into the Radarr postgres container.";
    };
    rootFolders = mkOption {
      type = listOf arrTypes.rootFolderType;
      default = [ ];
      example = [ { path = "/tank0/media/movies"; } ];
    };
    downloadClients = mkOption {
      type = listOf arrTypes.downloadClientType;
      default = [ ];
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.radarr = {
        enable = true;
        dataDir = cfg.dataDir;
        environmentFiles = [ config.sops.templates."radarr.env".path ];
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
            user = "radarr";
            mainDb = "radarr-main";
            logDb = "radarr-log";
          };
          log.analyticsEnabled = false;
        };
      };

      users.users.radarr.extraGroups = [ "media" ];

      sops.secrets = {
        "radarr/api-key".owner = "radarr";
        "radarr/postgres-password".owner = "radarr";
      };

      sops.templates."radarr.env" = {
        content = ''
          RADARR__AUTH__APIKEY=${config.sops.placeholder."radarr/api-key"}
          RADARR__POSTGRES__PASSWORD=${config.sops.placeholder."radarr/postgres-password"}
        '';
        owner = "radarr";
      };

      systemd.services.radarr.unitConfig.RequiresMountsFor = map (r: r.path) cfg.rootFolders;

      # Each rootFolder is sgid 2775 owned by radarr:media so *arr/qbittorrent/jellyfin
      # cross-access works (see media-storage).
      systemd.tmpfiles.rules = map (r: "d ${r.path} 2775 radarr media - -") cfg.rootFolders;

      theonecfg.services.postgres.instances.radarr = {
        version = "16";
        port = cfg.dbPort;
        databases = [
          "radarr-main"
          "radarr-log"
        ];
        owner = "radarr";
      };
    }

    (mkIf (cfg.rootFolders != [ ]) (
      declarative.mkArrApiPushService {
        name = "radarr-rootfolders";
        after = [ "radarr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."radarr/api-key".path;
        endpoint = "/api/v3/rootfolder";
        items = cfg.rootFolders;
        comparator = "path";
        noUpdate = true;
      }
    ))

    (mkIf (cfg.downloadClients != [ ]) (
      declarative.mkArrApiPushService {
        name = "radarr-downloadclients";
        after = [ "radarr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."radarr/api-key".path;
        endpoint = "/api/v3/downloadclient";
        items = cfg.downloadClients;
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
