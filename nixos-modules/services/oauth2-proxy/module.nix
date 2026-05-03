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
    str
    ;

  cfg = config.theonecfg.services.oauth2-proxy;
  kanidmCfg = config.theonecfg.services.kanidm;

in
{
  options.theonecfg.services.oauth2-proxy = {
    enable = mkEnableOption "oauth2-proxy as forward-auth gateway against Kanidm";
    domain = mkOption {
      type = str;
      default = "auth.${config.theonecfg.networking.lanDomain}";
      description = "Public hostname under which oauth2-proxy serves callbacks.";
    };
    cookieDomain = mkOption {
      type = str;
      default = ".${config.theonecfg.networking.lanDomain}";
      description = "Cookie domain so the same session works across all *.<lanDomain> vhosts.";
    };
    listenPort = mkOption {
      type = lib.types.int;
      default = 4180;
      description = "TCP port oauth2-proxy listens on (Caddy's forward_auth target).";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.oauth2-proxy = {
        enable = true;
        provider = "oidc";
        oidcIssuerUrl = "https://${kanidmCfg.domain}/oauth2/openid/oauth2-proxy";
        clientID = "oauth2-proxy";
        clientSecret = null;
        cookie = {
          domain = cfg.cookieDomain;
          secret = null;
        };
        email.domains = [ "*" ];
        reverseProxy = true;
        setXauthrequest = true;
        httpAddress = "127.0.0.1:${toString cfg.listenPort}";
        keyFile = config.sops.secrets."oauth2-proxy/env".path;
        extraConfig = {
          skip-provider-button = "true";
          whitelist-domain = cfg.cookieDomain;
        };
      };

      # Secret file is a systemd EnvironmentFile-style file with:
      #   OAUTH2_PROXY_CLIENT_SECRET=<from kanidm provisioning>
      #   OAUTH2_PROXY_COOKIE_SECRET=<32 random bytes, base64>
      sops.secrets."oauth2-proxy/env" = { };
    }

    (mkIf kanidmCfg.enable {
      services.kanidm.provision.systems.oauth2."oauth2-proxy" = {
        displayName = "Forward Auth";
        originUrl = "https://${cfg.domain}/oauth2/callback";
        originLanding = "https://${cfg.domain}/";
        basicSecretFile = config.sops.secrets."kanidm/oauth-proxy".path;
        scopeMaps."homelab-users" = [
          "openid"
          "profile"
          "email"
          "groups"
        ];
      };

      sops.secrets."kanidm/oauth-proxy" = { };
    })

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        reverse_proxy 127.0.0.1:${toString cfg.listenPort}
      '';

      # Named Caddyfile snippet that per-service modules import to gate
      # themselves behind oauth2-proxy. Usage in a vhost:
      #   import forward_auth_kanidm
      services.caddy.extraConfig = ''
        (forward_auth_kanidm) {
          forward_auth 127.0.0.1:${toString cfg.listenPort} {
            uri /oauth2/auth
            copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Groups
          }
        }
      '';
    })
  ]);
}
