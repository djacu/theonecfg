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
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
