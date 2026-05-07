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
      default = 3000;
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
    }

    (mkIf kanidmCfg.enable {
      services.grafana.settings."auth.generic_oauth" = {
        enabled = true;
        name = "Kanidm";
        client_id = "grafana";
        client_secret = "$__file{${config.sops.secrets."kanidm/oauth-grafana".path}}";
        scopes = "openid profile email groups";
        auth_url = "https://${kanidmCfg.domain}/ui/oauth2";
        token_url = "https://${kanidmCfg.domain}/oauth2/token";
        api_url = "https://${kanidmCfg.domain}/oauth2/openid/grafana/userinfo";
        allow_sign_up = true;
        role_attribute_path = "contains(groups[*], 'homelab-users') && 'Admin' || 'Viewer'";
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

      sops.secrets."kanidm/oauth-grafana".owner = "grafana";
    })

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
