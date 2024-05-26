inputs: {
  default =
    { ... }:
    {
      imports = [
        ./common.nix
        ./hypr.nix
        ./vm.nix
      ];
    };
}
