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

  cfg = config.theonecfg.packages.productivity;

in
{

  options.theonecfg.packages.productivity.enable = mkEnableOption "productivity package config";

  config = mkIf cfg.enable {
    home.packages = [

      pkgs.zathura

    ];
  };

}
