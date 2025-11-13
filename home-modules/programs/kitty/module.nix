{ lib, config, ... }:
let
  cfg = config.theonecfg.programs.kitty;
in
{
  options.theonecfg.programs.kitty.enable = lib.mkEnableOption "kitty config";

  config = lib.mkIf cfg.enable {
    programs.kitty.enable = true;
    programs.kitty.settings = {
      open_url_with = "firefox";
      copy_on_select = "clipboard";
      tab_bar_edge = "top";
      enable_audio_bell = "no";
    };
    programs.kitty.themeFile = "Nord";
  };
}
