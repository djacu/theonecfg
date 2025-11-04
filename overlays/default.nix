inputs: {

  default =
    let

      inherit (inputs.nixpkgs-lib)
        lib
        ;

      inherit (lib.fixedPoints)
        composeManyExtensions
        ;

      inherit (inputs.self.library.path)
        getDirectoryNames
        joinPathSegments
        ;

    in
    composeManyExtensions [

      inputs.nur.overlays.default

      # auto-add packages
      (final: prev: {
        theonecfg = final.lib.genAttrs (getDirectoryNames ./.) (
          dir: final.callPackage (joinPathSegments ./. "package.nix" dir) { }
        );
      })

    ];

}
