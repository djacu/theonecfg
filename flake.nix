{
  inputs = {
    disko.url = "github:nix-community/disko/";
    disko.inputs.nixpkgs.follows = "nixpkgs-unstable";
    home-manager-2505.url = "github:nix-community/home-manager/release-25.05";
    home-manager-2505.inputs.nixpkgs.follows = "nixpkgs-2505";
    impermanence.url = "github:nix-community/impermanence";
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
    nixpkgs-2505.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixvimcfg.url = "github:djacu/nixvimcfg";
    nur.url = "github:nix-community/nur";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = inputs: {
    checks = import ./checks inputs;
    formatter = import ./formatter inputs;
    formatterModule = import ./formatter-module inputs;
    homeConfigurations = import ./home-configurations inputs;
    homeModules = import ./home-modules inputs;
    legacyPackages = import ./legacy-packages inputs;
    library = import ./library inputs;
    nixosConfigurations = import ./nixos-configurations inputs;
    nixosModules = import ./nixos-modules inputs;
    overlays = import ./overlays inputs;
    packages = import ./packages inputs;
    theonecfg = import ./theonecfg inputs;
  };
}
