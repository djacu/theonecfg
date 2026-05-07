{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    mkOption
    ;

  inherit (lib.types)
    str
    ;

  cfg = config.theonecfg.services.caddy;

in
{
  options.theonecfg.services.caddy = {
    enable = mkEnableOption "Caddy reverse proxy";
    acmeEmail = mkOption {
      type = str;
      example = "you@example.com";
      description = ''
        Email registered with Let's Encrypt for renewal-failure and
        expiration notices. Required: Caddy refuses to issue certs
        without an email registered with the ACME directory.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.caddy = {
      enable = true;

      # Custom Caddy build with the Porkbun DNS provider compiled in. ACME
      # DNS-01 challenges write TXT records to the registered domain via
      # Porkbun's API, no inbound HTTP/443 from the public internet needed
      # — fits the LAN-only services pattern.
      #
      # The vendor hash below pins the resolved Go module set; it changes
      # whenever the plugin version or its transitive deps change. To
      # update: bump `plugins`, set `hash = lib.fakeHash`, run a build, and
      # paste the real hash from the error message.
      package = pkgs.caddy.withPlugins {
        plugins = [ "github.com/caddy-dns/porkbun@v0.3.1" ];
        hash = "sha256-pt4jyNcfacZKxzRH7zW7l2/+YfmVKWxGD4JTyWpvD1E=";
      };

      # `acme_dns` makes Caddy issue every vhost's cert via Porkbun DNS-01
      # by default — per-vhost certs (each subdomain lands in CT logs).
      # Wildcard cert is achievable later with explicit `*.scheelite.dev`
      # vhost matchers if subdomain enumeration via CT becomes a concern.
      globalConfig = ''
        acme_dns porkbun {
          api_key {env.PORKBUN_API_KEY}
          api_secret_key {env.PORKBUN_API_SECRET_KEY}
        }
        email ${cfg.acmeEmail}
      '';
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    # AdGuard's wildcard rewrite for *.${lanDomain} hijacks SOA/NS lookups
    # the Porkbun DNS plugin uses to determine the registrable zone — the
    # walk-up never finds scheelite.dev's real SOA and falls all the way to
    # the public `dev` TLD, then fails with INVALID_DOMAIN against Porkbun.
    # This snippet routes ACME-only DNS queries through public resolvers,
    # bypassing AdGuard. Each per-service vhost imports it.
    services.caddy.extraConfig = ''
      (acme_resolvers) {
        tls {
          resolvers 1.1.1.1 9.9.9.9
        }
      }
    '';

    # Porkbun creds are runtime-only — the global directive references
    # them as `{env.PORKBUN_API_KEY}` etc., resolved at startup.
    systemd.services.caddy.serviceConfig.EnvironmentFile =
      config.sops.templates."caddy-acme.env".path;

    sops.secrets = {
      "porkbun/api-key" = { };
      "porkbun/api-secret" = { };
    };

    sops.templates."caddy-acme.env" = {
      content = ''
        PORKBUN_API_KEY=${config.sops.placeholder."porkbun/api-key"}
        PORKBUN_API_SECRET_KEY=${config.sops.placeholder."porkbun/api-secret"}
      '';
      owner = "caddy";
      group = "caddy";
    };
  };
}
