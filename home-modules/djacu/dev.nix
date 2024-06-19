{
  lib,
  config,
  pkgs,
  inputs,
  system,
  ...
}:
let
  cfg = config.theonecfg.users.djacu;
in
{
  config = lib.mkIf (cfg.enable && cfg.dev.enable) {
    home.packages = with pkgs; [
      ansifilter
      as-tree
      bat
      bc
      bintools
      bottom
      curl
      dig
      dnsutils
      dt
      fd
      file
      grex
      gron
      htmlq
      iputils
      jo
      jq
      lsof
      man-pages
      man-pages-posix
      mdcat
      nix-diff
      nix-output-monitor
      nix-prefetch-scripts
      nix-tree
      nurl
      procs
      pstree
      ripgrep
      sd
      tealdeer
      traceroute
      yj

      inputs.nixvimcfg.packages.${system}.default
    ];

    xdg.enable = true;
    xdg.configFile."fd/ignore".text = ''
      .git
    '';

    home.sessionVariables = {
      EDITOR = "nvim";
    };

    programs.ssh.enable = true;

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
        diff.algorithm = "histogram";
        fetch.prune = true;
        fetch.prunetags = true;
        init.defaultBranch = "main";
        merge.conflictstyle = "zdiff3";
        rerere.enabled = true;
      };
    };

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
