{ lib, config, ... }:
let
  cfg = config.theonecfg.home.programs.kitty;
in
{
  options.theonecfg.home.programs.kitty.enable = lib.mkEnableOption "kitty config";

  config = lib.mkIf cfg.enable {

    programs.kitty.enable = true;
    programs.kitty.settings = {
      open_url_with = "firefox";
      copy_on_select = "clipboard";
      tab_bar_edge = "top";
      enable_audio_bell = "no";
    };
    programs.kitty.theme = "Nord";

    programs.kitty.environment = lib.mkIf config.theonecfg.home.programs.nixvimcfg.enable {
      EDITOR = "nvim";
    };

  };
}
