{
  config,
  lib,
  ...
}:
let

  inherit (lib.modules)
    mkDefault
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.profiles.desktop;

in
{

  options.theonecfg.profiles.desktop.enable = mkEnableOption "theonecfg desktop profile";

  config = mkIf cfg.enable {

    programs.ssh.startAgent = mkDefault false;

    theonecfg.desktops.plasma.enable = mkDefault true;
    theonecfg.features.audio.enable = mkDefault true;
    theonecfg.features.fonts.desktop.enable = mkDefault true;
    theonecfg.features.zoxide.enable = mkDefault true;
    theonecfg.networking.basic-network.enable = mkDefault true;

  };

}
