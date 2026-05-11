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

  # Per-app SyncCategories pushed as application fields. Each list
  # mirrors Prowlarr's compiled-in default for the app type plus
  # Newznab `8000` (Other). Several public-tracker Cardigann
  # definitions (notably LimeTorrents) classify keywordless-browse
  # results as `Other` rather than the apparent content category,
  # which fails the *arr's add-time test with 400 "no results in
  # configured categories". Including 8000 unblocks the test; runtime
  # keyword searches are specific enough that Other-category results
  # rarely match spuriously. AnimeSyncCategories is set on Sonarr
  # instances only (Radarr / Whisparr don't have that field).
  defaultProwlarrSyncFields = {
    sonarr = [
      {
        name = "syncCategories";
        value = [
          5000
          5010
          5020
          5030
          5040
          5045
          5050
          5090
          8000
        ];
      }
      {
        name = "animeSyncCategories";
        value = [
          5070
          8000
        ];
      }
    ];
    sonarr-anime = [
      {
        name = "syncCategories";
        value = [
          5000
          5010
          5020
          5030
          5040
          5045
          5050
          5090
          8000
        ];
      }
      {
        name = "animeSyncCategories";
        value = [
          5070
          8000
        ];
      }
    ];
    radarr = [
      {
        name = "syncCategories";
        value = [
          2000
          2010
          2020
          2030
          2040
          2045
          2050
          2060
          2070
          2080
          2090
          8000
        ];
      }
    ];
    whisparr = [
      {
        name = "syncCategories";
        value = [
          6000
          6010
          6020
          6030
          6040
          6045
          6050
          6070
          6080
          6090
          8000
        ];
      }
    ];
  };

  enabledArrs = lib.filterAttrs (_: c: c.enable or false) (
    lib.getAttrs (lib.attrNames arrImpls) config.theonecfg.services
  );

  baseUrl = "http://127.0.0.1:${toString cfg.port}";
  tagsSourceUrl = "${baseUrl}/api/v1/tag";

  # Auto-derived list of Prowlarr applications. Each item has an
  # `_apiKeyFile` marker that the push one-shot reads at runtime to
  # inject an `apiKey` entry into `fields`. Each *arr's `prowlarrTags`
  # propagates here, then resolves to int ids via `tagsSourceUrl` at
  # runtime.
  autoApplications = lib.mapAttrsToList (name: arrCfg: {
    name = arrDisplayNames.${name};
    implementation = arrImpls.${name};
    implementationName = arrImpls.${name};
    configContract = "${arrImpls.${name}}Settings";
    syncLevel = "fullSync";
    tags = arrCfg.prowlarrTags;
    fields = [
      {
        name = "prowlarrUrl";
        value = baseUrl;
      }
      {
        name = "baseUrl";
        value = "http://127.0.0.1:${toString arrCfg.port}";
      }
    ] ++ defaultProwlarrSyncFields.${name};
    _apiKeyFile = config.sops.secrets."${name}/api-key".path;
  }) enabledArrs;

  applications = if cfg.autoLinkArrs then autoApplications else cfg.applications;

  # Union of every tag label referenced by an indexer or application.
  # The `prowlarr-tags.service` one-shot creates these; the indexer/
  # application push services then resolve label→id at runtime.
  allTagLabels = lib.unique (
    lib.concatMap (i: i.tags or [ ]) cfg.indexers
    ++ lib.concatMap (a: a.tags or [ ]) applications
  );

  tagItems = map (label: { inherit label; }) allTagLabels;

  tagsAfter = lib.optional (tagItems != [ ]) "prowlarr-tags.service";

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

    # Tag reconciliation runs first; indexers + applications wait for it
    # so their label→id resolution finds the labels we declared.
    (mkIf (tagItems != [ ]) (declarative.mkArrApiPushService {
      name = "prowlarr-tags";
      after = [ "prowlarr.service" ];
      inherit baseUrl;
      apiKeyFile = config.sops.secrets."prowlarr/api-key".path;
      endpoint = "/api/v1/tag";
      items = tagItems;
      comparator = "label";
      noUpdate = true; # tag has no fields beyond the label itself
    }))

    (mkIf (cfg.indexers != [ ]) (declarative.mkArrApiPushService {
      name = "prowlarr-indexers";
      after = [ "prowlarr.service" ] ++ tagsAfter;
      inherit baseUrl tagsSourceUrl;
      apiKeyFile = config.sops.secrets."prowlarr/api-key".path;
      endpoint = "/api/v1/indexer";
      items = cfg.indexers;
    }))

    (mkIf (cfg.indexerProxies != [ ]) (declarative.mkArrApiPushService {
      name = "prowlarr-indexerproxies";
      after = [ "prowlarr.service" ];
      inherit baseUrl;
      apiKeyFile = config.sops.secrets."prowlarr/api-key".path;
      endpoint = "/api/v1/indexerproxy";
      items = cfg.indexerProxies;
    }))

    (mkIf (cfg.downloadClients != [ ]) (declarative.mkArrApiPushService {
      name = "prowlarr-downloadclients";
      after = [ "prowlarr.service" ];
      inherit baseUrl;
      apiKeyFile = config.sops.secrets."prowlarr/api-key".path;
      endpoint = "/api/v1/downloadclient";
      items = cfg.downloadClients;
    }))

    # Applications carry a per-*arr `_apiKeyFile` marker (sops path) and a
    # `tags` array of label strings; mkArrApiPushService's secret injection
    # + tags resolution handle both at runtime.
    #
    # extraApiWaits: Prowlarr's POST /api/v1/applications connection-tests
    # each *arr before accepting the entry, so all four *arrs must be
    # actually listening — not just have their systemd unit started. With
    # all four cold-starting in the same `nixos-rebuild switch` activation,
    # systemd.after ordering isn't sufficient (it waits for unit start,
    # not for the HTTP server to bind). Wait on each *arr's
    # /api/v3/system/status before any PUT.
    (mkIf (applications != [ ]) (declarative.mkArrApiPushService {
      name = "prowlarr-applications";
      after =
        [ "prowlarr.service" ]
        ++ tagsAfter
        ++ lib.mapAttrsToList (name: _: "${name}.service") enabledArrs;
      inherit baseUrl tagsSourceUrl;
      apiKeyFile = config.sops.secrets."prowlarr/api-key".path;
      endpoint = "/api/v1/applications";
      items = applications;
      extraApiWaits = lib.mapAttrsToList (name: arrCfg: {
        url = "http://127.0.0.1:${toString arrCfg.port}/api/v3/system/status";
        apiKeyFile = config.sops.secrets."${name}/api-key".path;
      }) enabledArrs;
    }))

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
