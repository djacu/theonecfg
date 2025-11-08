{ lib, config, ... }:
let
  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.programs.git.enable = lib.mkEnableOption "djacu git config";

  config = lib.mkIf (cfg.enable && cfg.programs.git.enable) {
    programs.git = {
      enable = true;
      userName = "Daniel Baker";
      userEmail = "dan@djacu.dev";
      aliases = {
        lg = "log --graph --decorate --pretty=oneline --abbrev-commit --all";
        patch = "diff --no-ext-diff";
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

        # gpg
        commit.gpgsign = true;
        tag.gpgSign = true;
        /*
          To see all keys
            gpg --list-keys

          To see just the line with the key needed for signing
            gpg --list-keys | awk '/pub   /'

          To see just the key
            gpg --list-keys | awk '/^pub[[:space:]]/ { split($2,a,"/"); print a[2] }'

          To get the ssh key from that
            gpg --list-keys \
            | awk '/^pub[[:space:]]/ { split($2,a,"/"); print a[2] }' \
            | xargs -r gpg --export-ssh-key
        */
        user.signingkey = "0x8C9CFEF8EE37DA95";
        gpg.format = "openpgp";
      };
    };
  };
}
