{ lib, config, ... }:
let
  cfg = config.theonecfg.plasma;
in
{
  options.theonecfg.plasma.enable = lib.mkEnableOption "plasma setup";

  config = lib.mkIf cfg.enable {
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };
    services.desktopManager.plasma6.enable = true;
  };
}
