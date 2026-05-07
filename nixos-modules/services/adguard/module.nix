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

  cfg = config.theonecfg.services.adguard;

in
{
  options.theonecfg.services.adguard = {
    enable = mkEnableOption "AdGuard Home (LAN DNS + ad blocking)";
    domain = mkOption {
      type = str;
      default = "adguard.${cfg.lanDomain}";
      description = "Caddy vhost serving AdGuard's web UI over HTTPS.";
    };
    port = mkOption {
      type = int;
      default = 3000;
      description = "AdGuard Home web UI port; bound to loopback (Caddy proxies from there).";
    };
    lanIp = mkOption {
      type = str;
      description = ''
        IP address advertised as the wildcard target for *.''${lanDomain}.
        The host that runs AdGuard supplies this — typically a let-binding
        also feeding networking.interfaces.<iface>.ipv4.addresses, so the
        IP is set in one place per host.
      '';
      example = "10.0.10.111";
    };
    lanDomain = mkOption {
      type = str;
      default = config.theonecfg.networking.lanDomain;
      description = "Wildcard domain whose subdomains resolve to the host.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # DNS listeners on 53 need explicit firewall rules. The web UI now
      # binds to loopback only and is reachable exclusively via Caddy on
      # 443 — no inbound firewall hole for the UI port.
      networking.firewall.allowedTCPPorts = [ 53 ];
      networking.firewall.allowedUDPPorts = [ 53 ];

      services.adguardhome = {
        enable = true;
        mutableSettings = false;
        host = "127.0.0.1";
        port = cfg.port;
        openFirewall = false;
        settings = {
          dns = {
            bind_hosts = [ "0.0.0.0" ];
            port = 53;
            # Bootstrap servers used to resolve the upstream DoH hostnames
            # themselves before AdGuard is fully online. Plain UDP/53.
            bootstrap_dns = [
              "1.1.1.1"
              "9.9.9.9"
            ];
            upstream_dns = [
              "https://1.1.1.1/dns-query"
              "https://9.9.9.9/dns-query"
            ];
          };
          filtering = {
            filtering_enabled = true;
            rewrites_enabled = true;
            # Rewrites live under filtering, not dns (current AdGuard
            # schema_version 33). Putting them under dns silently fails —
            # AdGuard ignores them and writes the default empty list at
            # filtering.rewrites.
            rewrites = [
              {
                domain = "*.${cfg.lanDomain}";
                answer = cfg.lanIp;
                enabled = true;
              }
              {
                domain = cfg.lanDomain;
                answer = cfg.lanIp;
                enabled = true;
              }
            ];
          };
        };
      };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      # AdGuard has its own admin login, so don't stack `forward_auth_kanidm`
      # on top — same pattern as Jellyfin/Paperless.
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
