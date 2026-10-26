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

  cfg = config.theonecfg.packages.nix;

in
{

  options.theonecfg.packages.nix.enable = mkEnableOption "nix package config";

  config = mkIf cfg.enable {
    home.packages = [

      pkgs.nix-diff
      pkgs.nix-output-monitor
      pkgs.nix-prefetch-scripts
      pkgs.nix-tree
      pkgs.nurl

    ];
  };

}
