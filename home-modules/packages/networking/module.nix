{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.options)
    mkEnableOption
    ;

  inherit (lib.modules)
    mkIf
    ;

  cfg = config.theonecfg.packages.networking;

in
{

  options.theonecfg.packages.networking.enable = mkEnableOption "networking package config";

  config = mkIf cfg.enable {
    home.packages = [

      pkgs.dig
      pkgs.dnsutils
      pkgs.iputils
      pkgs.traceroute

    ];
  };

}
