inputs: {
  default =
    { ... }:
    {
      imports = [
        ./audio.nix
        ./basic-network.nix
        ./common.nix
        ./desktop.nix
        ./dev.nix
        ./fonts.nix
        ./hypr.nix
        ./nvidia-1080ti.nix
        ./plasma.nix
        ./vm.nix
        ./zoxide.nix
        ./zsh.nix

        ./users

        inputs.disko.nixosModules.default
        inputs.impermanence.nixosModules.impermanence
      ];

      nixpkgs.overlays = [ inputs.self.overlays.default ];
    };
}
