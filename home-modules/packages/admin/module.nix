{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.options)
    mkEnableOption
    ;

  inherit (lib.modules)
    mkIf
    ;

  cfg = config.theonecfg.packages.admin;

in
{

  options.theonecfg.packages.admin.enable = mkEnableOption "admin package config";

  config = mkIf cfg.enable {
    home.packages = [

      pkgs.ansifilter
      pkgs.as-tree
      pkgs.bat
      pkgs.bc
      pkgs.bottom
      pkgs.curl
      pkgs.dt
      pkgs.file
      pkgs.grex
      pkgs.gron
      pkgs.jq
      pkgs.lsof
      pkgs.man-pages
      pkgs.man-pages-posix
      pkgs.procs
      pkgs.pstree
      pkgs.ripgrep
      pkgs.sd
      pkgs.tealdeer
      pkgs.yj

    ];
  };

}
