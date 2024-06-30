{ lib, config, ... }:
let
  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.git.enable = lib.mkEnableOption "djacu git config";

  config = lib.mkIf (cfg.enable && cfg.git.enable) {
    programs.git = {
      enable = true;
      userName = "Daniel Baker";
      userEmail = "daniel.n.baker@gmail.com";
      aliases = {
        lg = "log --graph --decorate --pretty=oneline --abbrev-commit --all";
      };
      difftastic.enable = true;
      difftastic.background = "dark";
      difftastic.color = "always";
      ignores = [
        "*.swp"
        "result*"
      ];
      extraConfig = {
        blame.ignoreRevsFile = ".git-blame-ignore-revs";
        core.editor = "nvim";
        diff.algorithm = "histogram";
        fetch.prune = true;
        fetch.prunetags = true;
        init.defaultBranch = "main";
        merge.conflictstyle = "zdiff3";
        rerere.enabled = true;
      };
    };
  };
}
