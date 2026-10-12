inputs:
let

  # inherits

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    attrValues
    genAttrs
    recurseIntoAttrs
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

  fixes = final: prev: {
  };

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

  misc = _final: _prev: {
    # This repo's counterpart of nixpkgs' modulesPath: lets a VM test import
    # a NixOS module by path without going through the flake outputs.
    theonecfgModulesPath = ../nixos-modules;
  };

  # VM tests, kept out of `default` so legacyPackages and the package jobs
  # never load nixos/lib. hydra-jobs/vm-tests.nix applies it.
  nixosTests = final: _prev: {
    theonecfgTests = recurseIntoAttrs (packagesFromDirectoryRecursive {
      inherit (final) callPackage;
      directory = ../package-sets/nixos-tests;
    });
  };

in
packageOverrides
// inputOverlays
// {

  inherit nixosTests;

  default = composeManyExtensions (
    (attrValues packageOverrides)
    ++ [
      inputs.nur.overlays.default
      toplevelOverlays
      misc
      fixes
    ]
    ++ (attrValues inputOverlays)
  );

}
