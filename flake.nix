{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
  };

  outputs =
    { self, nixpkgs }@inputs:
    {
      nixosModules = import ./nixos-modules inputs;
      nixosConfigurations = (import ./nixos-configurations inputs);

      packages.x86_64-linux.test-vm = self.nixosConfigurations.test-vm.config.system.build.vm;
    };
}
