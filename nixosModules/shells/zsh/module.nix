{
  config,
  lib,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.shells.zsh;

in
{

  options.theonecfg.shells.zsh.enable = mkEnableOption "zsh setup";

  config = mkIf cfg.enable {
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
