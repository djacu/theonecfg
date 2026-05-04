{
  config,
  lib,
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
    str
    ;

  cfg = config.theonecfg.services.immich;
  pgInstance = config.theonecfg.services.postgres.instances.immich;

in
{
  options.theonecfg.services.immich = {
    enable = mkEnableOption "Immich (photo management)";
    domain = mkOption {
      type = str;
      default = "immich.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 2283;
      description = "Immich server port; Caddy reverse-proxies to this.";
    };
    mediaLocation = mkOption {
      type = str;
      default = "/var/lib/immich";
    };
    dbPort = mkOption {
      type = int;
      default = 5434;
      description = "Host port that forwards into the immich postgres container.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.immich = {
        enable = true;
        host = "127.0.0.1";
        port = cfg.port;
        mediaLocation = cfg.mediaLocation;
        database = {
          enable = false;
          createDB = false;
          host = pgInstance.host;
          port = pgInstance.containerPort;
          name = "immich";
          user = "immich";
        };
        redis.enable = true;
      };

      # Per-service postgres for Immich. Needs pgvector for vector search of faces / objects.
      theonecfg.services.postgres.instances.immich = {
        version = "16";
        port = cfg.dbPort;
        extensions = [ "pgvector" ];
      };

      # Upstream immich module creates mediaLocation via tmpfiles.settings;
      # it does not set RequiresMountsFor.
      #
      # immich-server and immich-machine-learning both have wantedBy=multi-user.target
      # with no leader-follower edge between them; both touch mediaLocation, so
      # RequiresMountsFor goes on each.
      systemd.services.immich-server.unitConfig.RequiresMountsFor = [
        cfg.mediaLocation
      ];
      systemd.services.immich-machine-learning.unitConfig.RequiresMountsFor = [
        cfg.mediaLocation
      ];
    }

    (mkIf config.theonecfg.services.kanidm.enable {
      services.kanidm.provision.systems.oauth2.immich = {
        displayName = "Immich";
        originUrl = "https://${cfg.domain}/auth/login";
        originLanding = "https://${cfg.domain}/";
        basicSecretFile = config.sops.secrets."kanidm/oauth-immich".path;
        scopeMaps."homelab-users" = [
          "openid"
          "profile"
          "email"
        ];
      };
      sops.secrets."kanidm/oauth-immich" = { };
    })

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
