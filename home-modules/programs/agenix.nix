{
  lib,
  config,
  pkgs,
  inputs,
  system,
  release,
  ...
}:
let
  cfg = config.theonecfg.home.programs.agenix;
in
{

  options.theonecfg.home.programs.agenix.enable = lib.mkEnableOption "agenix config";

  config = {

    age = {
      package = pkgs.theonecfg.age;
      identityPaths = inputs.self.identities;
    };

    home.packages = [ inputs."agenix-${release}".packages.${system}.default ];

  };

}
