{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.theonecfg.home.programs.tmux;
in
{
  options.theonecfg.home.programs.tmux.enable = lib.mkEnableOption "tmux config";

  config = lib.mkIf cfg.enable {
    programs.tmux = {
      enable = true;
      aggressiveResize = true;
      clock24 = true;
      escapeTime = 10;
      keyMode = "vi";
      historyLimit = 50000;
      sensibleOnTop = false;
      terminal = "tmux-256color";
      plugins = with pkgs.tmuxPlugins; [
        fingers
        logging
        nord
      ];
      extraConfig = ''
        set-option -as terminal-features ",xterm-kitty:RGB"
      '';
    };

  };
}
