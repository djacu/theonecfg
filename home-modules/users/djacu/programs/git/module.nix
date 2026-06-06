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
        alias.bblame = "!f() { repo_root=$(git rev-parse --show-toplevel); if [ -e \"$repo_root/.git-blame-ignore-revs\" ]; then git blame --ignore-revs-file=\"$repo_root/.git-blame-ignore-revs\" \"$@\"; else git blame \"$@\"; fi; }; f";
        alias.lg = "log --graph --decorate --pretty=oneline --abbrev-commit --all";
        alias.patch = "diff --no-ext-diff";
        alias.reuse = "commit -C ORIG_HEAD";
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
