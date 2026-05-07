let

  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/master";
  pkgs = import nixpkgs {
    config = { };
    overlays = [ ];
  };

  lib = pkgs.lib;

  inherit (lib.attrsets)
    getAttrFromPath
    setAttrByPath
    ;

  inherit (lib.filesystem)
    baseNameOf
    pathIsDirectory
    pathIsRegularFile
    ;

  inherit (lib.lists)
    optionals
    ;

  rootFile = "flake.nix";
  rootDir = "nixos-modules";

  findUp =
    root: dir:
    let
      fileFound = pathIsRegularFile (dir + "/${root}");
      dirFound = pathIsDirectory (dir + "/${root}");
      baseName = [ (baseNameOf dir) ];
    in
    optionals (fileFound || dirFound) (findUp root (dir + "/..")) ++ baseName;

  # attrList = findUp rootFile ./.;
  # attrList = findUp rootFile ../../nixos-modules/hardware/brother-hll3280cdw;
  attrList = findUp rootDir ../../nixos-modules/hardware/brother-hll3280cdw;

  config = setAttrByPath attrList 2;

  cfg = getAttrFromPath attrList config;
in
config
