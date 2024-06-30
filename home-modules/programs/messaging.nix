{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.theonecfg.home.programs.messaging;
in
{
  options.theonecfg.home.programs.messaging.enable = lib.mkEnableOption "messaging config";

  config = lib.mkIf cfg.enable {

    home.packages = [
      pkgs.discord
      pkgs.element-desktop-wayland
      pkgs.signal-desktop
      pkgs.whatsapp-for-linux
    ];

    nixpkgs.config.allowUnfree = true;

  };
}
