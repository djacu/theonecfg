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
    anything
    attrsOf
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

  nfoSidecarsBin = pkgs.writers.writePython3Bin "whisparr-nfo-sidecars" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./nfo_sidecars.py);

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
    naming = mkOption {
      type = attrsOf anything;
      default = { };
      example = {
        renameEpisodes = true;
        javEpisodeFormat = "";
      };
      description = ''
        Fields of Whisparr's naming config (`/api/v3/config/naming`) to
        enforce on every switch. Keys left out keep whatever is already
        stored; the reconciler merges these over the live config and only
        PUTs when that changes something.

        Leaving ``javEpisodeFormat`` empty is meaningful rather than absent:
        FileNameBuilder falls back to ``standardEpisodeFormat`` for
        jav-typed series when the JAV format is blank, which is what keeps
        JAV scenes named like every other scene.
      '';
    };
    nfoSidecars = {
      enable = mkEnableOption ''
        periodic `.nfo` sidecars carrying the title and date parsed out of
        Whisparr's own filenames'';
      schedule = mkOption {
        type = str;
        default = "hourly";
        description = ''
          systemd OnCalendar expression for the sidecar sweep. Whisparr
          imports continuously, so this is how long a fresh import can sit
          mislabelled in Jellyfin.
        '';
      };
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

      # Order after the postgres container: the DB host is the container's
      # veth address and pg_hba trusts only that /24. Without this the
      # service can start before the container's route exists, connect via
      # the default route (wrong source IP), and hit a fatal, non-retried
      # pg_hba rejection. Same pattern as the stasharr service.
      systemd.services.whisparr.after = [ "container@postgres-whisparr.service" ];
      systemd.services.whisparr.requires = [ "container@postgres-whisparr.service" ];

      # Each rootFolder is sgid 2775 owned by whisparr:media so *arr/qbittorrent/jellyfin
      # cross-access works (see media-storage).
      systemd.tmpfiles.rules = map (r: "d ${r.path} 2775 whisparr media - -") cfg.rootFolders;

      # Jellyfin's movie resolver names a folder holding exactly one video
      # after the FOLDER, not the file (MovieResolver.FindMovie ends with
      # `movie.Name = Path.GetFileName(movie.ContainingFolderPath)`), so a
      # studio folder with a single scene enters the library as the studio
      # name and whichever metadata provider is enabled answers a query
      # built from that. The sidecar pins the title ahead of every remote
      # provider; see nfo_sidecars.py for the merge-order reasoning.
      #
      # Runs as whisparr: the root folders are 2775 whisparr:media, and the
      # sgid bit puts the sidecars in the media group for Jellyfin to read.
      systemd.services.whisparr-nfo-sidecars = mkIf cfg.nfoSidecars.enable {
        description = "Write .nfo sidecars next to Whisparr's imported files";
        unitConfig.RequiresMountsFor = map (r: r.path) cfg.rootFolders;
        serviceConfig = {
          Type = "oneshot";
          User = "whisparr";
          ExecStart = "${nfoSidecarsBin}/bin/whisparr-nfo-sidecars ${
            lib.escapeShellArgs (map (r: r.path) cfg.rootFolders)
          }";
        };
      };

      systemd.timers.whisparr-nfo-sidecars = mkIf cfg.nfoSidecars.enable {
        description = "Periodic .nfo sidecar sweep over Whisparr's root folders";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.nfoSidecars.schedule;
          Persistent = true;
        };
      };

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

    (mkIf (cfg.naming != { }) (
      declarative.mkArrNamingSync {
        name = "whisparr-naming";
        after = [ "whisparr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."whisparr/api-key".path;
        settings = cfg.naming;
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
        import acme_resolvers
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
