{
  config,
  lib,
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

  cfg = config.theonecfg.services.adguard;

in
{
  options.theonecfg.services.adguard = {
    enable = mkEnableOption "AdGuard Home (LAN DNS + ad blocking)";
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

  config = mkIf cfg.enable {
    # Upstream `openFirewall` only opens the web UI port (3000); the DNS
    # listener on 53 needs explicit rules.
    networking.firewall.allowedTCPPorts = [ 53 ];
    networking.firewall.allowedUDPPorts = [ 53 ];

    services.adguardhome = {
      enable = true;
      mutableSettings = false;
      openFirewall = true;
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
          rewrites = [
            {
              domain = "*.${cfg.lanDomain}";
              answer = cfg.lanIp;
            }
            {
              domain = cfg.lanDomain;
              answer = cfg.lanIp;
            }
          ];
        };
        filtering.enabled = true;
      };
    };
  };
}
