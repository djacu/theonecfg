{
  lib,
  config,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.theonecfg.users.djacu;
in
{
  imports = [
    ./desktop.nix
    ./dev.nix
    ./fish.nix
    ./firefox.nix
    ./git.nix
  ];

  options.theonecfg.users.djacu.enable = lib.mkEnableOption "djacu user config";

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.username = lib.mkDefault "djacu";
        home.homeDirectory = "/home/${config.home.username}";

        programs.home-manager.enable = true;

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
              "https://nca.cachix.org"
            ];
            trusted-public-keys = [
              "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
              "nca.cachix.org-1:c8uthjrwGpyXBTBar6GWm8edgD6bErzugvlDyjNTfRc="
            ];
          };
        };

        home.packages = with pkgs; [
          tree
          unzip
          usbutils
          w3m
          zip
        ];
      }
    ]
  );
}
