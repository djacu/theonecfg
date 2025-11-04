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

      inherit (inputs.self.library.path)
        getDirectoryNames
        joinPathSegments
        ;

    in
    {
      imports = [
        inputs.disko.nixosModules.default
        inputs.impermanence.nixosModules.impermanence
      ] ++ map (joinPathSegments ./. "module.nix") (getDirectoryNames ./.);

      nixpkgs.overlays = [ inputs.self.overlays.default ];
    };
}
