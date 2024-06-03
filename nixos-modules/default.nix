inputs: {
  default =
    { ... }:
    {
      imports = [
        ./basic-network.nix
        ./common.nix
        ./hypr.nix
        ./vm.nix

        inputs.disko.nixosModules.default
        inputs.impermanence.nixosModules.impermanence
      ];
    };
}
