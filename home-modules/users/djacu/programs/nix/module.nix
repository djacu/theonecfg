{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let

  cfg = config.theonecfg.users.djacu;

in
{

  options.theonecfg.users.djacu.programs.nix.enable = lib.mkEnableOption "djacu nix config";

  config = lib.mkIf (cfg.enable && cfg.programs.nix.enable) {
    nix = {
      package = pkgs.nix;
      registry.nixpkgs.flake = inputs.nixpkgs-unstable;
      settings = {
        nix-path = [ "nixpkgs=${inputs.nixpkgs-unstable}" ];
        experimental-features = [
          "nix-command"
          "flakes"
        ];

        substituters = [
          "https://cache.nixos.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        ];
      };
    };
  };

}
