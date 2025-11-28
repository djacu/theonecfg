inputs:
let

  # inherits

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    attrValues
    genAttrs
    ;

  inherit (lib.filesystem)
    packagesFromDirectoryRecursive
    ;

  inherit (lib.fixedPoints)
    composeManyExtensions
    ;

  inherit (inputs.self.library.path)
    getDirectoryNames
    joinParentToPaths
    ;

  # overlays

  toplevelOverlays =
    final: prev:
    packagesFromDirectoryRecursive {
      inherit (final) callPackage;
      inherit (prev) newScope;
      directory = ../package-sets/top-level;
    };

  packageOverrides =
    (
      parent:
      (genAttrs (getDirectoryNames parent) (
        dir:
        import (
          joinParentToPaths parent [
            dir
            "overlay.nix"
          ]
        )
      ))
    )
      ./package-overrides;

  inputOverlays = genAttrs (getDirectoryNames ../overlays/input-overlays) (
    dir: import ../overlays/input-overlays/${dir}/overlay.nix inputs
  );

in
packageOverrides
// inputOverlays
// {

  default = composeManyExtensions (
    (attrValues packageOverrides)
    ++ [
      inputs.nur.overlays.default
      toplevelOverlays
    ]
    ++ (attrValues inputOverlays)
  );

}
