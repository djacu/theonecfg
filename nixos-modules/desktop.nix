{ lib, config, ... }:
let
  cfg = config.theonecfg.desktop;
in
{
  options.theonecfg.desktop.enable = lib.mkEnableOption "desktop setup";

  config = lib.mkIf cfg.enable {
    theonecfg.dev.enable = true;
    theonecfg.fonts.dev.enable = true;
  };
}
