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
    ;

  cfg = config.theonecfg.services.caddy;

in
{
  options.theonecfg.services.caddy.enable = mkEnableOption "Caddy reverse proxy";

  config = mkIf cfg.enable {
    services.caddy = {
      enable = true;
      # Use Caddy's internal CA for all vhosts. Homelab vhosts live on a
      # non-public TLD (.literallyhell) which Caddy's auto-HTTPS does
      # NOT classify as internal (the hard-coded list is .localhost,
      # .local, .internal, .home.arpa). Without this directive Caddy
      # tries ACME, fails, and TLS handshakes return "internal error".
      globalConfig = ''
        local_certs
      '';
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
