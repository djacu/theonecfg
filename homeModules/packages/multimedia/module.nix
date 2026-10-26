{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.options)
    mkEnableOption
    ;

  inherit (lib.modules)
    mkIf
    ;

  cfg = config.theonecfg.packages.multimedia;

in
{

  options.theonecfg.packages.multimedia.enable = mkEnableOption "multimedia package config";

  config = mkIf cfg.enable {
    home.packages = [

      pkgs.ffmpeg
      pkgs.imv
      pkgs.mediainfo
      pkgs.pavucontrol
      pkgs.vlc
      pkgs.yt-dlp

    ];
  };

}
