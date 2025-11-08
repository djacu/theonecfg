{
  lib,
  config,
  inputs,
  system,
  ...
}:
let
  cfg = config.theonecfg.programs.nixvimcfg;
in
{
  options.theonecfg.programs.nixvimcfg.enable = lib.mkEnableOption "nixvimcfg config";

  config = lib.mkIf cfg.enable {
    home.packages = [ inputs.nixvimcfg.packages.${system}.default ];

    home.sessionVariables = {
      EDITOR = "nvim";
    };

  };
}
