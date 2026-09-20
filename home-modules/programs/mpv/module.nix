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

  cfg = config.theonecfg.programs.mpv;

in
{

  options.theonecfg.programs.mpv.enable = mkEnableOption "mpv config";

  config = mkIf cfg.enable {
    programs.mpv = {

      enable = true;

      scripts = [
        pkgs.mpvScripts.mpris
        pkgs.mpvScripts.thumbfast
        pkgs.mpvScripts.uosc
      ];

      config = {
        hwdec = "auto";

        border = false;
        osd-bar = false;

        slang = "eng";
        sub-auto = "fuzzy";

        keep-open = true;
        save-position-on-quit = true;

        screenshot-format = "png";
        screenshot-directory = "~/Pictures/mpv";
      };

    };
  };

}
