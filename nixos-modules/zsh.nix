{ lib, config, ... }:
let
  cfg = config.theonecfg.zsh;
in
{
  options.theonecfg.zsh.enable = lib.mkEnableOption "zsh setup";

  config = lib.mkIf cfg.enable {
    programs.zsh = {
      enable = true;
      autosuggestions.enable = true;
      autosuggestions.async = true;
      autosuggestions.strategy = [
        "history"
        "completion"
      ];
      enableCompletion = true;
      enableLsColors = true;
      histSize = 10000;
      shellAliases = {
        lse = "ls -Fho";
        lsa = "lse -A";
      };
      syntaxHighlighting.enable = true;
      syntaxHighlighting.highlighters = [
        "main"
        "brackets"
        "cursor"
        "root"
      ];
    };

    users.defaultUserShell = "/run/current-system/sw/bin/zsh";
    system.userActivationScripts.zshrc = ''
      touch .zshrc
    '';
  };
}
