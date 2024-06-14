{
  inputs = {
    disko.url = "github:nix-community/disko/";
    disko.inputs.nixpkgs.follows = "nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager/release-24.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    impermanence.url = "github:nix-community/impermanence";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware";
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    {
      homeConfigurations = import ./home-configurations inputs;
      homeModules = import ./home-modules inputs;
      nixosConfigurations = import ./nixos-configurations inputs;
      nixosModules = import ./nixos-modules inputs;

      packages.x86_64-linux.test-vm = self.nixosConfigurations.test-vm.config.system.build.vm;
    };
}
