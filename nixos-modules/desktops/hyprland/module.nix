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

  cfg = config.theonecfg.desktops.hyprland;

in
{

  options.theonecfg.desktops.hyprland.enable = mkEnableOption "theonecfg hyprland setup";

  config = mkIf cfg.enable {

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
