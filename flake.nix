{
  inputs = {
    disko.url = "github:nix-community/disko/";
    disko.inputs.nixpkgs.follows = "nixpkgs-unstable";
    home-manager-2405.url = "github:nix-community/home-manager/release-24.05";
    home-manager-2405.inputs.nixpkgs.follows = "nixpkgs-2405";
    home-manager-2411.url = "github:nix-community/home-manager/release-24.11";
    home-manager-2411.inputs.nixpkgs.follows = "nixpkgs-2411";
    home-manager-2505.url = "github:nix-community/home-manager/release-25.05";
    home-manager-2505.inputs.nixpkgs.follows = "nixpkgs-2505";
    impermanence.url = "github:nix-community/impermanence";
    nixpkgs-jfly.url = "github:jfly/nixpkgs/c815ac27c26d76236ed59002b60ebb988cf697d6";
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
    nixpkgs-2405.url = "github:nixos/nixpkgs/nixos-24.05";
    nixpkgs-2411.url = "github:nixos/nixpkgs/nixos-24.11";
    nixpkgs-2505.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixvimcfg.url = "github:djacu/nixvimcfg";
    nur.url = "github:nix-community/nur";
  };

  outputs = inputs: {
    formatter = import ./formatter inputs;
    homeConfigurations = import ./home-configurations inputs;
    homeModules = import ./home-modules inputs;
    legacyPackages = import ./legacy-packages inputs;
    library = import ./library inputs;
    nixosConfigurations = import ./nixos-configurations inputs;
    nixosModules = import ./nixos-modules inputs;
    overlays = import ./overlays inputs;
    packages = import ./packages inputs;
  };
}
