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
    listFilesRecursive
    packagesFromDirectoryRecursive
    ;

  inherit (lib.fixedPoints)
    composeManyExtensions
    ;

  inherit (lib.lists)
    filter
    ;

  inherit (inputs.self.library.path)
    getDirectoryNames
    ;

  # overlays

  # Fixes for upstream nixpkgs packages: every overlay.nix under ./fixes.
  fixes = composeManyExtensions (
    map import (filter (path: baseNameOf path == "overlay.nix") (listFilesRecursive ./fixes))
  );

  # One overlay per flake input that ships packages; each file takes `inputs`.
  inputOverlays = genAttrs (getDirectoryNames ./inputOverlays) (
    dir: import ./inputOverlays/${dir}/overlay.nix inputs
  );

  misc = _final: _prev: {
    # This repo's counterpart of nixpkgs' modulesPath: lets a VM test import
    # a NixOS module by path without going through the flake outputs.
    theonecfgModulesPath = ../nixosModules;
  };

  # VM tests, nested like nixpkgs' nixosTests.
  nixosTests = final: _prev: {
    theonecfgNixosTests = recurseIntoAttrs (packagesFromDirectoryRecursive {
      inherit (final) callPackage;
      directory = ./nixosTests;
    });
  };

  # No newScope: with it the root directory becomes a scope whose bookkeeping
  # attributes leak into pkgs.
  topLevel =
    final: _prev:
    packagesFromDirectoryRecursive {
      inherit (final) callPackage;
      directory = ./topLevel;
    };

in
inputOverlays
// {

  inherit
    fixes
    nixosTests
    topLevel
    ;

  default = composeManyExtensions (
    [
      fixes
      inputs.nur.overlays.default
      topLevel
      nixosTests
      misc
    ]
    ++ (attrValues inputOverlays)
  );

}
