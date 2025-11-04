inputs: {

  default =
    let

      inherit (builtins)
        readDir
        ;

      inherit (inputs.nixpkgs-lib)
        lib
        ;

      inherit (lib.attrsets)
        attrNames
        filterAttrs
        ;

      inherit (lib.fixedPoints)
        composeManyExtensions
        ;

      inherit (lib.trivial)
        const
        ;

      getDirectories =
        path: attrNames (filterAttrs (const (fileType: fileType == "directory")) (readDir path));

    in
    composeManyExtensions [

      inputs.nur.overlays.default

      # auto-add packages
      (final: prev: {
        theonecfg = final.lib.genAttrs (getDirectories ./.) (
          dir: final.callPackage ./${dir}/package.nix { }
        );
      })

    ];

}
