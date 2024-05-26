{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
  };

  outputs =
    { self, nixpkgs }@inputs:
    {

      nixosModules = import ./nixos-modules inputs;

      nixosConfigurations.linuxvm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          (
            { ... }:
            {
              #theonecfg.hypr.enable = true;
              theonecfg.simple-vm.enable = true;
              theonecfg.common.enable = true;
            }
          )
        ];
      };

      packages.x86_64-linux.linuxvm = self.nixosConfigurations.linuxvm.config.system.build.vm;
    };
}
