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

  cfg = config.theonecfg.desktops.plasma;

in
{

  options.theonecfg.desktops.plasma.enable = mkEnableOption "theonecfg plasma setup";

  config = mkIf cfg.enable {

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };
    services.desktopManager.plasma6.enable = true;

  };

}
