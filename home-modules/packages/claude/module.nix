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

  cfg = config.theonecfg.packages.claude;

in
{

  options.theonecfg.packages.claude.enable = mkEnableOption "claude package config";

  config = mkIf cfg.enable {

    home.packages = [

      pkgs.claude-code
      pkgs.mcp-nixos

    ];

    nixpkgs.config.allowUnfree = true;

  };

}
