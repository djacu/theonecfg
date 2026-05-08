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

  cfg = config.theonecfg.services.monitoring.grafana;
  promCfg = config.theonecfg.services.monitoring.prometheus;
  lokiCfg = config.theonecfg.services.monitoring.loki;
  kanidmCfg = config.theonecfg.services.kanidm;

in
{
  options.theonecfg.services.monitoring.grafana = {
    enable = mkEnableOption "Grafana";
    domain = mkOption {
      type = str;
      default = "grafana.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      # Grafana upstream default is 3000, but AdGuard's web UI also defaults
      # to 3000 — pick a non-colliding port so both can coexist on loopback.
      default = 3001;
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.grafana = {
        enable = true;
        settings = {
          server = {
            http_addr = "127.0.0.1";
            http_port = cfg.port;
            domain = cfg.domain;
            root_url = "https://${cfg.domain}/";
          };
          # NixOS 26.05 removed the default secret_key; Grafana uses this to
          # encrypt sensitive values (datasource credentials, plugin secrets)
          # at rest in its DB. Read from sops via Grafana's $__file provider
          # so the value never enters the world-readable Nix store.
          security.secret_key = "$__file{${config.sops.secrets."grafana/secret-key".path}}";
        };

        provision = {
          enable = true;
          datasources.settings.datasources =
            (lib.optional promCfg.enable {
              name = "Prometheus";
              type = "prometheus";
              url = "http://127.0.0.1:${toString promCfg.port}";
              isDefault = true;
            })
            ++ (lib.optional lokiCfg.enable {
              name = "Loki";
              type = "loki";
              url = "http://127.0.0.1:${toString lokiCfg.port}";
            });
        };
      };

      sops.secrets."grafana/secret-key".owner = "grafana";
    }

    (mkIf kanidmCfg.enable {
      services.grafana.settings."auth.generic_oauth" = {
        enabled = true;
        name = "Kanidm";
        client_id = "grafana";
        # Same OAuth2 client secret as kanidm-provision uses, but read from
        # a grafana-owned sops template — the original sops file is
        # kanidm-owned so kanidm-provision can read it during provisioning.
        # See `sops.templates."grafana-oauth-client-secret"` below.
        client_secret = "$__file{${config.sops.templates."grafana-oauth-client-secret".path}}";
        scopes = "openid profile email groups";
        auth_url = "https://${kanidmCfg.domain}/ui/oauth2";
        token_url = "https://${kanidmCfg.domain}/oauth2/token";
        api_url = "https://${kanidmCfg.domain}/oauth2/openid/grafana/userinfo";
        allow_sign_up = true;
        # Kanidm refuses authorize requests without PKCE
        # (allowInsecureClientDisablePkce defaults to false on the kanidm
        # side; without this, Grafana's authorize call is rejected with
        # "Error Code: InvalidState").
        use_pkce = true;
        # Kanidm emits the `groups` claim in SPN form
        # ("<group>@<kanidm-domain>"), not the bare group name. JMESPath's
        # `contains` does exact string match, so match against the full SPN.
        role_attribute_path = "contains(groups[*], 'homelab-users@${kanidmCfg.domain}') && 'Admin' || 'Viewer'";
      };

      services.kanidm.provision.systems.oauth2.grafana = {
        displayName = "Grafana";
        originUrl = "https://${cfg.domain}/login/generic_oauth";
        originLanding = "https://${cfg.domain}/";
        basicSecretFile = config.sops.secrets."kanidm/oauth-grafana".path;
        scopeMaps."homelab-users" = [
          "openid"
          "profile"
          "email"
          "groups"
        ];
      };

      # kanidm-provision reads this as the kanidm user when registering the
      # OAuth2 client; the template below renders the same value into a
      # grafana-readable file for Grafana's $__file provider.
      sops.secrets."kanidm/oauth-grafana" = {
        owner = "kanidm";
        group = "kanidm";
      };

      sops.templates."grafana-oauth-client-secret" = {
        content = "${config.sops.placeholder."kanidm/oauth-grafana"}";
        owner = "grafana";
        group = "grafana";
      };
    })

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
