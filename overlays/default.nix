inputs: {

  default =

    let

      inherit (inputs.nixpkgs-unstable.lib) composeManyExtensions filterAttrs;
      inherit (builtins) attrNames readDir;

      getDirectories =
        path: attrNames (filterAttrs (_: fileType: fileType == "directory") (readDir path));

    in

    composeManyExtensions [

      inputs.nur.overlay

      # auto-add packages
      (final: prev: {
        theonecfg = final.lib.genAttrs (getDirectories ./.) (
          dir: final.callPackage ./${dir}/package.nix { }
        );
      })

    ];

}
