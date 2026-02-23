{ lib, config, ... }:
let
  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.programs.git.enable = lib.mkEnableOption "djacu git config";

  config = lib.mkIf (cfg.enable && cfg.programs.git.enable) {

    programs.difftastic = {
      enable = true;
      git.enable = true;
      options.background = "dark";
      options.color = "always";
    };

    programs.git = {
      enable = true;
      ignores = [
        "*.swp"
        "result*"
      ];
      lfs.enable = true;
      settings = {
        alias.amend = "commit --amend --no-edit";
        alias.lg = "log --graph --decorate --pretty=oneline --abbrev-commit --all";
        alias.patch = "diff --no-ext-diff";
        alias.reuse = "commit -C ORIG_HEAD";
        blame.ignoreRevsFile = ".git-blame-ignore-revs";
        core.editor = "nvim";
        diff.algorithm = "histogram";
        fetch.prune = true;
        fetch.prunetags = true;
        init.defaultBranch = "main";
        merge.conflictstyle = "zdiff3";
        rerere.enabled = true;
        user.email = "dan@djacu.dev";
        user.name = "Daniel Baker";
      };
    };

  };
}
