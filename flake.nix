{
  inputs = {
    disko.url = "github:nix-community/disko/";
    disko.inputs.nixpkgs.follows = "nixpkgs-unstable";
    home-manager-unstable.url = "github:nix-community/home-manager";
    home-manager-unstable.inputs.nixpkgs.follows = "nixpkgs-unstable";
    impermanence.url = "github:nix-community/impermanence";
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixvimcfg.url = "github:djacu/nixvimcfg";
    nur.url = "github:nix-community/nur";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = inputs: {
    checks = import ./checks inputs;
    formatter = import ./formatter inputs;
    formatterModule = import ./formatterModule inputs;
    homeConfigurations = import ./homeConfigurations inputs;
    homeModules = import ./homeModules inputs;
    legacyPackages = import ./legacyPackages inputs;
    library = import ./library inputs;
    nixosConfigurations = import ./nixosConfigurations inputs;
    nixosModules = import ./nixosModules inputs;
    overlays = import ./overlays inputs;
    theonecfg = import ./theonecfg inputs;
  };
}
