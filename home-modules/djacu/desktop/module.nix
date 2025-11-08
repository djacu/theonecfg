{ lib, config, ... }:
let
  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.desktop.enable = lib.mkEnableOption "djacu desktop config";

  config = lib.mkIf (cfg.enable && cfg.desktop.enable) {

    theonecfg.users.djacu.firefox.enable = true;
    theonecfg.users.djacu.gpg.enable = true;

    theonecfg.home.programs.kitty.enable = true;

    theonecfg.packages.messaging.enable = true;
    theonecfg.packages.productivity.enable = true;

  };
}
