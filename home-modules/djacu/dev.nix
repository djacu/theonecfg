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

    theonecfg.home.programs.fd.enable = true;
    theonecfg.home.programs.nixvimcfg.enable = true;
    theonecfg.home.programs.tmux.enable = true;

    programs.ssh.enable = true;

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

    ];
  };
}
