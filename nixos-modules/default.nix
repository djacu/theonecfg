inputs: {
  default =
    { ... }:
    {
      imports = [
        ./basic-network.nix
        ./common.nix
	./desktop.nix
	./dev.nix
	./fonts.nix
        ./hypr.nix
        ./vm.nix
	./zoxide.nix
	./zsh.nix

        inputs.disko.nixosModules.default
        inputs.impermanence.nixosModules.impermanence
      ];
    };
}
