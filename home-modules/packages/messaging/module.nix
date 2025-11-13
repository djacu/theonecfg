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

  cfg = config.theonecfg.packages.messaging;

in
{

  options.theonecfg.packages.messaging.enable = mkEnableOption "messaging package config";

  config = mkIf cfg.enable {

    home.packages = [

      pkgs.discord
      pkgs.element-desktop
      pkgs.signal-desktop
      pkgs.whatsapp-for-linux

    ];

    nixpkgs.config.allowUnfree = true;

  };

}
