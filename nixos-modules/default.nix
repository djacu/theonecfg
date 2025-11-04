inputs: {
  default =
    {
      lib,
      ...
    }:
    let

      inherit (builtins)
        readDir
        ;

      inherit (lib.attrsets)
        attrNames
        filterAttrs
        ;

      inherit (lib.lists)
        map
        ;

      inherit (lib.trivial)
        const
        ;

    in
    {
      imports = [
        inputs.disko.nixosModules.default
        inputs.impermanence.nixosModules.impermanence
      ]
      ++ map (directory: ./${directory}/module.nix) (
        attrNames (filterAttrs (const (filetype: filetype == "directory")) (readDir ./.))
      );

      nixpkgs.overlays = [ inputs.self.overlays.default ];
    };
}
