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
    str
    ;

  cfg = config.theonecfg.services.nextcloud;
  pgInstance = config.theonecfg.services.postgres.instances.nextcloud;

in
{
  options.theonecfg.services.nextcloud = {
    enable = mkEnableOption "Nextcloud";
    domain = mkOption {
      type = str;
      default = "nextcloud.${config.theonecfg.networking.lanDomain}";
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/nextcloud";
    };
    internalPort = mkOption {
      type = int;
      default = 8081;
      description = "Local-only port nginx (auto-configured by services.nextcloud) listens on. Caddy reverse-proxies to this.";
    };
    dbPort = mkOption {
      type = int;
      default = 5433;
      description = "Host port that forwards into the nextcloud postgres container.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.nextcloud = {
        enable = true;
        hostName = cfg.domain;
        package = pkgs.nextcloud30;
        datadir = cfg.dataDir;
        https = false;

        config = {
          dbtype = "pgsql";
          dbhost = "${pgInstance.host}:${toString pgInstance.containerPort}";
          dbname = "nextcloud";
          dbuser = "nextcloud";
          adminuser = "admin";
          adminpassFile = config.sops.secrets."nextcloud/admin-password".path;
        };

        # Caddy is in front; tell Nextcloud to generate https:// links.
        settings = {
          trusted_proxies = [ "127.0.0.1" ];
          overwriteprotocol = "https";
          overwritehost = cfg.domain;
          default_phone_region = "US";
        };

        extraApps = {
          inherit (config.services.nextcloud.package.packages.apps) user_oidc;
        };
        extraAppsEnable = true;
      };

      # NixOS' nextcloud module auto-creates an nginx vhost. Make it local-only
      # so it doesn't fight Caddy on port 80.
      services.nginx.virtualHosts.${cfg.domain}.listen = [
        {
          addr = "127.0.0.1";
          port = cfg.internalPort;
        }
      ];

      theonecfg.services.postgres.instances.nextcloud = {
        version = "16";
        port = cfg.dbPort;
      };

      sops.secrets."nextcloud/admin-password".owner = "nextcloud";

      # Upstream nextcloud module creates ${datadir}/config and ${datadir}/data
      # via systemd.tmpfiles.rules, which auto-creates the dataDir parent.
      # Upstream does not set RequiresMountsFor, so we add it on the leader.
      #
      # nextcloud-setup is the leader: phpfpm-nextcloud has Before=, and
      # nextcloud-cron / nextcloud-update-db chain off it. Setting
      # RequiresMountsFor on the leader transitively orders the rest.
      systemd.services.nextcloud-setup.unitConfig.RequiresMountsFor = [
        cfg.dataDir
      ];
    }

    (mkIf config.theonecfg.services.kanidm.enable {
      services.kanidm.provision.systems.oauth2.nextcloud = {
        displayName = "Nextcloud";
        originUrl = "https://${cfg.domain}/apps/user_oidc/code";
        originLanding = "https://${cfg.domain}/";
        basicSecretFile = config.sops.secrets."kanidm/oauth-nextcloud".path;
        scopeMaps."homelab-users" = [
          "openid"
          "profile"
          "email"
          "groups"
        ];
      };
      sops.secrets."kanidm/oauth-nextcloud" = { };
    })

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        reverse_proxy 127.0.0.1:${toString cfg.internalPort}
      '';
    })
  ]);
}
