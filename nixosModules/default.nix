inputs: {
  default =
    {
      lib,
      ...
    }:
    let

      inherit (lib.lists)
        map
        ;

      inherit (lib.trivial)
        flip
        pipe
        ;

      inherit (inputs.self.library.path)
        getDirectoryNames
        joinParentToPaths
        ;

    in
    {
      imports = [
        inputs.disko.nixosModules.default
        inputs.impermanence.nixosModules.impermanence
        inputs.sops-nix.nixosModules.sops
      ]
      ++ map (flip pipe [
        (joinParentToPaths ./.)
        (flip joinParentToPaths "module.nix")
      ]) (getDirectoryNames ./.);

      nixpkgs.overlays = [ inputs.self.overlays.default ];
    };
}
