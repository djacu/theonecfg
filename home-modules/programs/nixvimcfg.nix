{
  lib,
  config,
  inputs,
  system,
  ...
}:
let
  cfg = config.theonecfg.home.programs.nixvimcfg;
in
{
  options.theonecfg.home.programs.nixvimcfg.enable = lib.mkEnableOption "nixvimcfg config";

  config = lib.mkIf cfg.enable {
    home.packages = [ inputs.nixvimcfg.packages.${system}.default ];

    home.sessionVariables = {
      EDITOR = "nvim";
    };

  };
}
