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

  cfg = config.theonecfg.services.whisparr;
  declarative = theonecfg.library.declarative pkgs;
  arrTypes = theonecfg.library.arrTypes;

in
{
  options.theonecfg.services.whisparr = {
    enable = mkEnableOption "Whisparr";
    domain = mkOption {
      type = str;
      default = "whisparr.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 6969;
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/whisparr";
    };
    dbPort = mkOption {
      type = int;
      default = 5439;
      description = "Host port that forwards into the Whisparr postgres container.";
    };
    rootFolders = mkOption {
      type = listOf arrTypes.rootFolderType;
      default = [ ];
      example = [ { path = "/tank0/media/adult"; } ];
    };
    downloadClients = mkOption {
      type = listOf arrTypes.downloadClientType;
      default = [ ];
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.whisparr = {
        enable = true;
        dataDir = cfg.dataDir;
        environmentFiles = [ config.sops.templates."whisparr.env".path ];
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
            host = "127.0.0.1";
            port = cfg.dbPort;
            user = "whisparr";
            mainDb = "whisparr-main";
            logDb = "whisparr-log";
          };
          log.analyticsEnabled = false;
        };
      };

      sops.secrets = {
        "whisparr/api-key".owner = "whisparr";
        "whisparr/postgres-password".owner = "whisparr";
      };

      sops.templates."whisparr.env" = {
        content = ''
          WHISPARR__AUTH__APIKEY=${config.sops.placeholder."whisparr/api-key"}
          WHISPARR__POSTGRES__PASSWORD=${config.sops.placeholder."whisparr/postgres-password"}
        '';
        owner = "whisparr";
      };

      systemd.services.whisparr.unitConfig.RequiresMountsFor = map (r: r.path) cfg.rootFolders;

      theonecfg.services.postgres.instances.whisparr = {
        version = "16";
        port = cfg.dbPort;
        databases = [
          "whisparr-main"
          "whisparr-log"
        ];
        owner = "whisparr";
      };
    }

    (mkIf (cfg.rootFolders != [ ]) (
      declarative.mkArrApiPushService {
        name = "whisparr-rootfolders";
        after = [ "whisparr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."whisparr/api-key".path;
        endpoint = "/api/v3/rootfolder";
        items = cfg.rootFolders;
        comparator = "path";
      }
    ))

    (mkIf (cfg.downloadClients != [ ]) (
      declarative.mkArrApiPushService {
        name = "whisparr-downloadclients";
        after = [ "whisparr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."whisparr/api-key".path;
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
