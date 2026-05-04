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

  cfg = config.theonecfg.services.prowlarr;
  declarative = theonecfg.library.declarative pkgs;
  arrTypes = theonecfg.library.arrTypes;
  pgInstance = config.theonecfg.services.postgres.instances.prowlarr;

  # Maps theonecfg.services.<name> → Prowlarr's Application implementation +
  # configContract names. Sonarr-anime is "Sonarr" — same binary/API.
  arrImpls = {
    sonarr = "Sonarr";
    sonarr-anime = "Sonarr";
    radarr = "Radarr";
    whisparr = "Whisparr";
  };
  arrDisplayNames = {
    sonarr = "Sonarr";
    sonarr-anime = "Sonarr (Anime)";
    radarr = "Radarr";
    whisparr = "Whisparr";
  };

  enabledArrs = lib.filterAttrs (_: c: c.enable or false) (
    lib.getAttrs (lib.attrNames arrImpls) config.theonecfg.services
  );

  # Auto-derived list of Prowlarr applications. Each item has an
  # `_apiKeyFile` marker that the prowlarr-applications one-shot reads at
  # runtime to inject an `apiKey` entry into `fields`.
  autoApplications = lib.mapAttrsToList (name: arrCfg: {
    name = arrDisplayNames.${name};
    implementation = arrImpls.${name};
    implementationName = arrImpls.${name};
    configContract = "${arrImpls.${name}}Settings";
    syncLevel = "fullSync";
    tags = [ ];
    fields = [
      {
        name = "prowlarrUrl";
        value = "http://127.0.0.1:${toString cfg.port}";
      }
      {
        name = "baseUrl";
        value = "http://127.0.0.1:${toString arrCfg.port}";
      }
    ];
    _apiKeyFile = config.sops.secrets."${name}/api-key".path;
  }) enabledArrs;

  applications = if cfg.autoLinkArrs then autoApplications else cfg.applications;

  applicationsFile = pkgs.writeText "prowlarr-applications.json" (builtins.toJSON applications);

  curlPkg = declarative.mkSecureCurl {
    name = "prowlarr";
    apiKeyFile = config.sops.secrets."prowlarr/api-key".path;
  };

in
{
  options.theonecfg.services.prowlarr = {
    enable = mkEnableOption "Prowlarr (indexer manager)";
    domain = mkOption {
      type = str;
      default = "prowlarr.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 9696;
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/prowlarr";
    };
    dbPort = mkOption {
      type = int;
      default = 5440;
    };
    indexers = mkOption {
      type = listOf arrTypes.indexerType;
      default = [ ];
      description = ''
        Declarative indexer configurations. The structure is implementation-specific
        — refer to GET /api/v1/indexer/schema. Each entry must have a `name`.
        Indexers requiring credentials should reference sops secrets in their
        `fields` array.
      '';
    };
    downloadClients = mkOption {
      type = listOf arrTypes.downloadClientType;
      default = [ ];
    };
    indexerProxies = mkOption {
      type = listOf arrTypes.indexerType;
      default = [ ];
      description = "Indexer proxies (e.g., FlareSolverr) for Cloudflare-protected indexers.";
    };
    autoLinkArrs = mkOption {
      type = bool;
      default = true;
      description = ''
        Auto-derive Prowlarr applications from enabled
        theonecfg.services.{sonarr,sonarr-anime,radarr,whisparr}. The api keys
        are read from each *arr's sops file at runtime by the prowlarr-applications
        one-shot.
      '';
    };
    applications = mkOption {
      type = listOf arrTypes.applicationType;
      default = [ ];
      description = ''
        Manual application entries (used when autoLinkArrs = false). Each may
        include an `_apiKeyFile` field whose contents will be injected as the
        `apiKey` value in `fields` at runtime.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Upstream prowlarr's NixOS module sets DynamicUser=true and
      # exposes no user/group option. That breaks our sops pattern
      # (owner = "prowlarr" needs a static user that exists at sops
      # activation time, before the service starts). Override to
      # static user, matching sonarr/radarr/whisparr's upstream pattern.
      users.users.prowlarr = {
        isSystemUser = true;
        group = "prowlarr";
        home = cfg.dataDir;
      };
      users.groups.prowlarr = { };

      systemd.services.prowlarr.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "prowlarr";
        Group = "prowlarr";
      };

      services.prowlarr = {
        enable = true;
        dataDir = cfg.dataDir;
        environmentFiles = [ config.sops.templates."prowlarr.env".path ];
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
            user = "prowlarr";
            mainDb = "prowlarr-main";
            logDb = "prowlarr-log";
          };
          log.analyticsEnabled = false;
        };
      };

      sops.secrets = {
        "prowlarr/api-key".owner = "prowlarr";
        "prowlarr/postgres-password".owner = "prowlarr";
      };

      sops.templates."prowlarr.env" = {
        content = ''
          PROWLARR__AUTH__APIKEY=${config.sops.placeholder."prowlarr/api-key"}
          PROWLARR__POSTGRES__PASSWORD=${config.sops.placeholder."prowlarr/postgres-password"}
        '';
        owner = "prowlarr";
      };

      # prowlarr isn't in NixOS's `ids.nix` (upstream uses DynamicUser),
      # and we override it to a static user above. Reference the user/group
      # by name in tmpfiles — systemd-tmpfiles accepts both, and the
      # users.users.prowlarr declaration above guarantees the user exists.
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 prowlarr prowlarr - -"
      ];

      systemd.services.prowlarr.unitConfig.RequiresMountsFor = [ cfg.dataDir ];

      theonecfg.services.postgres.instances.prowlarr = {
        version = "16";
        port = cfg.dbPort;
        databases = [
          "prowlarr-main"
          "prowlarr-log"
        ];
        owner = "prowlarr";
      };
    }

    (mkIf (cfg.indexers != [ ]) (
      declarative.mkArrApiPushService {
        name = "prowlarr-indexers";
        after = [ "prowlarr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."prowlarr/api-key".path;
        endpoint = "/api/v1/indexer";
        items = cfg.indexers;
      }
    ))

    (mkIf (cfg.indexerProxies != [ ]) (
      declarative.mkArrApiPushService {
        name = "prowlarr-indexerproxies";
        after = [ "prowlarr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."prowlarr/api-key".path;
        endpoint = "/api/v1/indexerproxy";
        items = cfg.indexerProxies;
      }
    ))

    (mkIf (cfg.downloadClients != [ ]) (
      declarative.mkArrApiPushService {
        name = "prowlarr-downloadclients";
        after = [ "prowlarr.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."prowlarr/api-key".path;
        endpoint = "/api/v1/downloadclient";
        items = cfg.downloadClients;
      }
    ))

    # Applications: special case because each application needs its target
    # *arr's API key injected from a sops file at runtime. Inline systemd
    # one-shot rather than mkArrApiPushService.
    (mkIf (applications != [ ]) {
      systemd.services.prowlarr-applications = {
        description = "Reconcile Prowlarr applications (links to *arr instances)";
        after = [
          "prowlarr.service"
        ]
        ++ lib.mapAttrsToList (name: _: "${name}.service") enabledArrs;
        requires = [ "prowlarr.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
          curlPkg
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          ${declarative.waitForApiScript {
            url = "http://127.0.0.1:${toString cfg.port}/api/v1/system/status";
          }}

          # Read declarative applications, transform each to inject the
          # actual apiKey from the file referenced by _apiKeyFile.
          desired=$(jq -c '.[]' ${applicationsFile} | while read -r app; do
            keyfile=$(jq -r '._apiKeyFile' <<< "$app")
            apikey=$(tr -d '\n' < "$keyfile")
            jq --arg k "$apikey" \
              '.fields = (.fields // []) + [{"name": "apiKey", "value": $k}]
               | del(._apiKeyFile)' \
              <<< "$app"
          done | jq -s '.')

          baseUrl="http://127.0.0.1:${toString cfg.port}/api/v1/applications"
          current=$(curl-prowlarr "$baseUrl")

          # Map names to existing IDs
          declare -A existing_ids
          while IFS=$'\t' read -r key id; do
            [ -n "$key" ] && existing_ids["$key"]="$id"
          done < <(jq -r '.[] | "\(.name)\t\(.id)"' <<< "$current")

          # Track desired names for delete pass
          declare -A desired_keys
          while read -r item; do
            key=$(jq -r '.name' <<< "$item")
            desired_keys["$key"]=1

            if [ -n "''${existing_ids[$key]:-}" ]; then
              id="''${existing_ids[$key]}"
              payload=$(jq --argjson id "$id" '. + { id: $id }' <<< "$item")
              echo "PUT applications/$id ($key)"
              curl-prowlarr -X PUT -d "$payload" "$baseUrl/$id" >/dev/null
            else
              echo "POST applications ($key)"
              curl-prowlarr -X POST -d "$item" "$baseUrl" >/dev/null
            fi
          done < <(jq -c '.[]' <<< "$desired")

          # Delete any application not in desired
          while IFS=$'\t' read -r key id; do
            if [ -n "$key" ] && [ -z "''${desired_keys[$key]:-}" ]; then
              echo "DELETE applications/$id ($key)"
              curl-prowlarr -X DELETE "$baseUrl/$id" >/dev/null
            fi
          done < <(jq -r '.[] | "\(.name)\t\(.id)"' <<< "$current")
        '';
      };
    })

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
