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
  pgInstance = config.theonecfg.services.postgres.instances.paperless;
  kanidmCfg = config.theonecfg.services.kanidm;

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
          PAPERLESS_DBHOST = pgInstance.host;
          PAPERLESS_DBPORT = pgInstance.containerPort;
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

      # Wire paperless's django-allauth to Kanidm. Settings without secrets
      # go in `services.paperless.settings` (baked into the unit env). The
      # JSON in PAPERLESS_SOCIALACCOUNT_PROVIDERS contains the OAuth client
      # secret, so it lives in a sops-rendered EnvironmentFile instead of
      # the Nix store.
      services.paperless.settings.PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
      services.paperless.environmentFile = config.sops.templates."paperless.env".path;

      sops.templates."paperless.env" = {
        content = ''
          PAPERLESS_SOCIALACCOUNT_PROVIDERS={"openid_connect":{"OAUTH_PKCE_ENABLED":true,"APPS":[{"provider_id":"kanidm","name":"Kanidm","client_id":"paperless","secret":"${config.sops.placeholder."kanidm/oauth-paperless"}","settings":{"server_url":"https://${kanidmCfg.domain}/oauth2/openid/paperless","token_auth_method":"client_secret_basic"}}]}}
        '';
        owner = "paperless";
      };

      # kanidm-provision reads this file as the kanidm user when registering
      # the OAuth2 client; the sops template above reads it via root at
      # render time and embeds it into paperless.env.
      sops.secrets."kanidm/oauth-paperless" = {
        owner = "kanidm";
        group = "kanidm";
      };
    })

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';

      # Public URL behind the Caddy vhost. Without this, Django's CSRF
      # middleware rejects POSTs whose Origin doesn't match what paperless
      # thinks it's serving (it sees the Caddy → 127.0.0.1:28981 proxy hop
      # as the origin). Paperless uses this to derive ALLOWED_HOSTS,
      # CSRF_TRUSTED_ORIGINS, and OIDC redirect URLs. No trailing slash.
      services.paperless.settings.PAPERLESS_URL = "https://${cfg.domain}";
    })
  ]);
}
