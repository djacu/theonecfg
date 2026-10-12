{
  # The platforms supported. VM tests need KVM, which the builders have on
  # x86_64 only.
  supportedSystems ? [ "x86_64-linux" ],

  # The system evaluating this expression.
  evalSystem ? builtins.currentSystem or "x86_64-linux",

  # The path to Nixpkgs.
  nixpkgs ? null,
}@args:
let

  inherit
    (import ./common.nix (
      args
      // {
        extraOverlays = [ self.overlays.nixosTests ];
      }
    ))
    releaseLib
    self
    ;

  inherit (releaseLib)
    mapTestOn
    packagePlatforms
    pkgs
    ;

in
mapTestOn (packagePlatforms {
  inherit (pkgs) theonecfgTests;
})
