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

  cfg = config.theonecfg.profiles.server;

in
{

  options.theonecfg.profiles.server.enable = mkEnableOption "theonecfg server profile";

  config = mkIf cfg.enable {

    programs.ssh.startAgent = mkDefault false;

    theonecfg.features.audio.enable = mkDefault true;
    theonecfg.features.fonts.desktop.enable = mkDefault true;
    theonecfg.features.zoxide.enable = mkDefault true;

  };

}
