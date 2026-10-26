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

  cfg = config.theonecfg.packages.developer;

in
{

  options.theonecfg.packages.developer.enable = mkEnableOption "developer package config";

  config = mkIf cfg.enable {
    home.packages = [

      pkgs.bintools
      pkgs.curl
      pkgs.gh
      pkgs.grex
      pkgs.gron
      pkgs.htmlq
      pkgs.jo
      pkgs.jq
      pkgs.mdcat
      pkgs.ripgrep
      pkgs.sd
      pkgs.tealdeer
      pkgs.yj

    ];
  };

}
