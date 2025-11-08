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

  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.profiles.desktop.enable = mkEnableOption "djacu desktop profile";

  config = mkIf (cfg.enable && cfg.profiles.desktop.enable) {

    theonecfg.users.djacu.firefox.enable = true;

    theonecfg.programs.kitty.enable = true;

    theonecfg.packages.messaging.enable = true;
    theonecfg.packages.productivity.enable = true;

  };
}
