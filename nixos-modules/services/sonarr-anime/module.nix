{
  config,
  lib,
  pkgs,
  theonecfg,
  utils,
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

  cfg = config.theonecfg.services.sonarr-anime;
  declarative = theonecfg.library.declarative pkgs;
  arrTypes = theonecfg.library.arrTypes;

  # Mirrors upstream services.sonarr's mkServarrSettingsEnvVars (in
  # nixos/modules/services/misc/servarr/settings-options.nix). Recursively
  # walks settings, producing { <PREFIX>__<SECTION>__<KEY> = "value"; ... }.
  mkSettingsEnvVars =
    prefix: settings:
    lib.pipe settings [
      (lib.mapAttrsRecursive (
        path: value:
        lib.optionalAttrs (value != null) {
          name = lib.toUpper "${prefix}__${lib.concatStringsSep "__" path}";
          value = toString (if lib.isBool value then lib.boolToString value else value);
        }
      ))
      (lib.collect (x: lib.isString (x.name or null) && lib.isString (x.value or null)))
      lib.listToAttrs
    ];

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
      user = "sonarr-anime";
      mainDb = "sonarr-anime-main";
      logDb = "sonarr-anime-log";
    };
    log.analyticsEnabled = false;
  };

in
{
  options.theonecfg.services.sonarr-anime = {
    enable = mkEnableOption "Sonarr (anime instance — second Sonarr alongside the main one)";
    domain = mkOption {
      type = str;
      default = "sonarr-anime.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 8990;
      description = "Distinct from the main Sonarr's 8989.";
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/sonarr-anime";
    };
    dbPort = mkOption {
      type = int;
      default = 5437;
      description = "Host port forwarding into the sonarr-anime postgres container.";
    };
    rootFolders = mkOption {
      type = listOf arrTypes.rootFolderType;
      default = [ ];
      example = [ { path = "/tank0/media/anime"; } ];
    };
    downloadClients = mkOption {
      type = listOf arrTypes.downloadClientType;
      default = [ ];
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Our own systemd service (services.sonarr is singleton, so the anime
      # instance is built from scratch using the upstream Sonarr package).
      # Hardening mirrors upstream's services.sonarr.
      systemd.services.sonarr-anime = {
        description = "Sonarr (anime)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        environment = mkSettingsEnvVars "SONARR" settings;
        serviceConfig = {
          Type = "simple";
          User = "sonarr-anime";
          Group = "sonarr-anime";
          EnvironmentFile = [ config.sops.templates."sonarr-anime.env".path ];
          ExecStart = utils.escapeSystemdExecArgs [
            (lib.getExe pkgs.sonarr)
            "-nobrowser"
            "-data=${cfg.dataDir}"
          ];
          Restart = "on-failure";

          # Hardening (cloned from upstream services.sonarr)
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          ProtectHome = true;
          ProtectClock = true;
          ProtectKernelLogs = true;
          PrivateTmp = true;
          PrivateDevices = true;
          PrivateUsers = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          RemoveIPC = true;
          UMask = "0022";
          ProtectHostname = true;
          ProtectProc = "invisible";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
            "~@debug"
            "~@mount"
            "@chown"
          ];
        };
        unitConfig.RequiresMountsFor = [ cfg.dataDir ] ++ map (r: r.path) cfg.rootFolders;
      };

      users.users.sonarr-anime = {
        group = "sonarr-anime";
        home = cfg.dataDir;
        isSystemUser = true;
      };
      users.groups.sonarr-anime = { };

      sops.secrets = {
        "sonarr-anime/api-key".owner = "sonarr-anime";
        "sonarr-anime/postgres-password".owner = "sonarr-anime";
      };

      sops.templates."sonarr-anime.env" = {
        content = ''
          SONARR__AUTH__APIKEY=${config.sops.placeholder."sonarr-anime/api-key"}
          SONARR__POSTGRES__PASSWORD=${config.sops.placeholder."sonarr-anime/postgres-password"}
        '';
        owner = "sonarr-anime";
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 sonarr-anime sonarr-anime - -"
      ];

      theonecfg.services.postgres.instances.sonarr-anime = {
        version = "16";
        port = cfg.dbPort;
        databases = [
          "sonarr-anime-main"
          "sonarr-anime-log"
        ];
        owner = "sonarr-anime";
      };
    }

    (mkIf (cfg.rootFolders != [ ]) (
      declarative.mkArrApiPushService {
        name = "sonarr-anime-rootfolders";
        after = [ "sonarr-anime.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."sonarr-anime/api-key".path;
        endpoint = "/api/v3/rootfolder";
        items = cfg.rootFolders;
        comparator = "path";
      }
    ))

    (mkIf (cfg.downloadClients != [ ]) (
      declarative.mkArrApiPushService {
        name = "sonarr-anime-downloadclients";
        after = [ "sonarr-anime.service" ];
        baseUrl = "http://127.0.0.1:${toString cfg.port}";
        apiKeyFile = config.sops.secrets."sonarr-anime/api-key".path;
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
