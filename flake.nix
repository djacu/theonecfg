{
  inputs = {
    disko.url = "github:nix-community/disko/";
    disko.inputs.nixpkgs.follows = "nixpkgs-unstable";
    home-manager-2405.url = "github:nix-community/home-manager/release-24.05";
    home-manager-2405.inputs.nixpkgs.follows = "nixpkgs-2405";
    impermanence.url = "github:nix-community/impermanence";
    nixpkgs-2405.url = "github:nixos/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixvimcfg.url = "github:djacu/nixvimcfg";
    nur.url = "github:nix-community/nur";
  };

  outputs =
    { self, ... }@inputs:
    {
      formatter = import ./formatter inputs;
      homeConfigurations = import ./home-configurations inputs;
      homeModules = import ./home-modules inputs;
      legacyPackages = import ./legacy-packages inputs;
      nixosConfigurations = import ./nixos-configurations inputs;
      nixosModules = import ./nixos-modules inputs;
      overlays = import ./overlays inputs;
      packages = import ./packages inputs;

      # packages.x86_64-linux.test-vm = self.nixosConfigurations.test-vm.config.system.build.vm;
    };
}
