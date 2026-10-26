{
  # The platforms supported.
  supportedSystems ? [
    "aarch64-linux"
    "x86_64-linux"
  ],

  # The system evaluating this expression.
  evalSystem ? builtins.currentSystem or "x86_64-linux",

  # The path to Nixpkgs.
  nixpkgs ? null,
}@args:
let

  inherit (import ./common.nix args)
    lib
    releaseLib
    self
    ;

  inherit (lib.attrsets)
    getAttrs
    ;

  inherit (releaseLib)
    mapTestOn
    packagePlatforms
    pkgs
    ;

  inherit (self.library.path)
    getDirectoryNames
    ;

in
# Every package directory under overlays/topLevel is a job.
mapTestOn (packagePlatforms (getAttrs (getDirectoryNames ../overlays/topLevel) pkgs))
