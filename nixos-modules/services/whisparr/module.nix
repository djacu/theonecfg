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

  cfg = config.theonecfg.services.whisparr;
  declarative = theonecfg.library.declarative pkgs;
  arrTypes = theonecfg.library.arrTypes;
  pgInstance = config.theonecfg.services.postgres.instances.whisparr;
  qbtCfg = config.theonecfg.services.qbittorrent;

  autoDownloadClients = lib.optional (cfg.autoQbittorrent && qbtCfg.enable) (
    declarative.mkQbtDownloadClient {
      port = qbtCfg.webUiPort;
      category = "whisparr";
    }
  );
  effectiveDownloadClients = autoDownloadClients ++ cfg.downloadClients;

  # Whisparr is a Sonarr-v3 fork; its Bootstrap.cs only binds PostgresOptions
  # and SSL cert paths to .NET configuration. ApiKey, AuthenticationMethod, and
  # AuthenticationRequired are all read exclusively from config.xml via
  # IConfigFileProvider.GetValueEnum (verified against
  # src/NzbDrone.Core/Configuration/ConfigFileProvider.cs:209-220). No env-var
  # path exists. We upsert each on every start; the values survive Whisparr's
  # own startup rewrites (DeleteOldValues only strips unknown keys; these are
  # known properties on ConfigFileProvider so they're kept verbatim).
  whisparrConfigSync = pkgs.writeShellApplication {
    name = "whisparr-config-sync";
    runtimeInputs = [
      pkgs.gnused
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      config="${cfg.dataDir}/config.xml"
      apikey="$(tr -d '\n' < "${config.sops.secrets."whisparr/api-key".path}")"

      if [ ! -f "$config" ]; then
        printf '<Config>\n</Config>\n' > "$config"
        chown whisparr:whisparr "$config"
        chmod 0600 "$config"
      fi

      # Replace if present, otherwise insert before </Config>. Idempotent.
      upsert() {
        local field=$1 value=$2
        if grep -q "<$field>" "$config"; then
          sed -i "s|<$field>[^<]*</$field>|<$field>$value</$field>|" "$config"
        else
          sed -i "s|</Config>|  <$field>$value</$field>\n</Config>|" "$config"
        fi
      }

      upsert ApiKey "$apikey"
      upsert AuthenticationMethod Forms
      upsert AuthenticationRequired DisabledForLocalAddresses
    '';
  };

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
    autoQbittorrent = mkOption {
      type = bool;
      default = true;
      description = ''
        Auto-add a qBittorrent download-client entry pointing at
        ``theonecfg.services.qbittorrent`` (category = "whisparr")
        whenever both modules are enabled.
      '';
    };
    downloadClients = mkOption {
      type = listOf arrTypes.downloadClientType;
      default = [ ];
      description = ''
        Manual download client entries. Merged with the auto-derived
        qBittorrent entry (when ``autoQbittorrent = true``).
      '';
    };
    prowlarrTags = mkOption {
      type = listOf str;
      default = [ ];
      description = ''
        Tags carried on this *arr's Prowlarr application entry. See
        sonarr.prowlarrTags for routing semantics.
      '';
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
            host = pgInstance.host;
            port = pgInstance.containerPort;
            user = "whisparr";
            mainDb = "whisparr-main";
            logDb = "whisparr-log";
          };
          log.analyticsEnabled = false;
        };
      };

      users.users.whisparr.extraGroups = [ "media" ];

      systemd.services.whisparr.serviceConfig.ExecStartPre = lib.mkAfter [
        "+${whisparrConfigSync}/bin/whisparr-config-sync"
      ];

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

      # Each rootFolder is sgid 2775 owned by whisparr:media so *arr/qbittorrent/jellyfin
      # cross-access works (see media-storage).
      systemd.tmpfiles.rules = map (r: "d ${r.path} 2775 whisparr media - -") cfg.rootFolders;

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
        noUpdate = true;
      }
    ))

    (mkIf (effectiveDownloadClients != [ ]) (
      declarative.mkArrApiPushService {
        name = "whisparr-downloadclients";
        after = [ "whisparr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."whisparr/api-key".path;
        endpoint = "/api/v3/downloadclient";
        items = effectiveDownloadClients;
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
