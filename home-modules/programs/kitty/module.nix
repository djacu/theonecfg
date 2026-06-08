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
      # Disable auto config reload (negative value = off). We don't
      # need it: this kitty.conf is rendered into the nix store and
      # symlinked into ~/.config/kitty, so it never changes in place
      # — each home-manager generation produces a new store path and
      # kitty has to be restarted to see it anyway. Leaving auto-
      # reload on also triggers kitty 0.47.0-0.47.1's __watch_conf__
      # bug where it recursively watches subdirs and exhausts the
      # inotify budget (upstream issue #10102, fixed in 0.47.2).
      auto_reload_config = "-1";
    };
    programs.kitty.themeFile = "Nord";
  };
}
