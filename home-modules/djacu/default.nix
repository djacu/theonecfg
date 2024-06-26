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
