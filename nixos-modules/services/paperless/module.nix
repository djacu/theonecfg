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

  cfg = config.theonecfg.services.paperless;

in
{
  options.theonecfg.services.paperless = {
    enable = mkEnableOption "Paperless-ngx (document management)";
    domain = mkOption {
      type = str;
      default = "paperless.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 28981;
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/paperless";
    };
    mediaDir = mkOption {
      type = str;
      default = "/var/lib/paperless/media";
    };
    consumptionDir = mkOption {
      type = str;
      default = "/var/lib/paperless/consume";
    };
    dbPort = mkOption {
      type = int;
      default = 5435;
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.paperless = {
        enable = true;
        address = "127.0.0.1";
        port = cfg.port;
        dataDir = cfg.dataDir;
        mediaDir = cfg.mediaDir;
        consumptionDir = cfg.consumptionDir;
        passwordFile = config.sops.secrets."paperless/admin-password".path;

        settings = {
          PAPERLESS_DBENGINE = "postgresql";
          PAPERLESS_DBHOST = "127.0.0.1";
          PAPERLESS_DBPORT = cfg.dbPort;
          PAPERLESS_DBNAME = "paperless";
          PAPERLESS_DBUSER = "paperless";
          PAPERLESS_OCR_LANGUAGE = "eng";
          PAPERLESS_TIME_ZONE = "America/Los_Angeles";
        };
      };

      theonecfg.services.postgres.instances.paperless = {
        version = "16";
        port = cfg.dbPort;
      };

      sops.secrets."paperless/admin-password".owner = "paperless";

      # Upstream paperless module creates dataDir, mediaDir, consumptionDir
      # via systemd.tmpfiles.settings, and sets
      # `unitConfig.RequiresMountsFor = defaultServiceConfig.ReadWritePaths`
      # on the paperless-scheduler leader. Nothing to add.
    }

    (mkIf config.theonecfg.services.kanidm.enable {
      services.kanidm.provision.systems.oauth2.paperless = {
        displayName = "Paperless";
        originUrl = "https://${cfg.domain}/accounts/oidc/kanidm/login/callback/";
        originLanding = "https://${cfg.domain}/";
        basicSecretFile = config.sops.secrets."kanidm/oauth-paperless".path;
        scopeMaps."homelab-users" = [
          "openid"
          "profile"
          "email"
        ];
      };
      sops.secrets."kanidm/oauth-paperless" = { };
    })

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
