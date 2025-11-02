{ lib, config, ... }:
let
  cfg = config.theonecfg.hypr;
in
{
  options.theonecfg.hypr = {
    enable = lib.mkEnableOption "hyprland setup";
  };

  config = lib.mkIf cfg.enable {
    services.xserver.enable = true;

    services.xserver.displayManager.gdm = {
      enable = true;
      wayland = true;
    };

    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
    };

    hardware.opengl.enable = true;
  };
}
