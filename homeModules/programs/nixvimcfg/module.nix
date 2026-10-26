{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.theonecfg.programs.nixvimcfg;
in
{
  options.theonecfg.programs.nixvimcfg.enable = lib.mkEnableOption "nixvimcfg config";

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.theonecfg.nixvimcfg ];

    home.sessionVariables = {
      EDITOR = "nvim";
    };

  };
}
