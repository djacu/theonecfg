{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.dev.enable = lib.mkEnableOption "djacu dev config";

  config = lib.mkIf (cfg.enable && cfg.dev.enable) {
    theonecfg.users.djacu.git.enable = true;
    theonecfg.users.djacu.fish.enable = true;

    theonecfg.home.programs.fd.enable = true;
    theonecfg.home.programs.fish.enable = true;
    theonecfg.home.programs.nixvimcfg.enable = true;
    theonecfg.home.programs.tmux.enable = true;

    programs.ssh.enable = true;
    # https://nix-community.github.io/home-manager/options.xhtml#opt-programs.ssh.enableDefaultConfig
    # programs.ssh.matchBlocks."*" = {
    #   forwardAgent = false;
    #   addKeysToAgent = "no";
    #   compression = false;
    #   serverAliveInterval = 0;
    #   serverAliveCountMax = 3;
    #   hashKnownHosts = false;
    #   userKnownHostsFile = "~/.ssh/known_hosts";
    #   controlMaster = "no";
    #   controlPath = "~/.ssh/master-%r@%n:%p";
    #   controlPersist = "no";
    # };
    programs.ssh.matchBlocks.argentite = {
      hostname = "argentite";
      forwardAgent = true;
    };

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
      file
      gh
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
      zathura

    ];
  };
}
