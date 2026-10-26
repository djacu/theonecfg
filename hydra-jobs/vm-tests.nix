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
        # @args carries only what the caller passed, so the default above
        # must be forwarded by hand or common.nix uses its own two systems.
        inherit supportedSystems;
      }
    ))
    releaseLib
    ;

  inherit (releaseLib)
    mapTestOn
    packagePlatforms
    pkgs
    ;

in
mapTestOn (packagePlatforms {
  inherit (pkgs) theonecfgNixosTests;
})
