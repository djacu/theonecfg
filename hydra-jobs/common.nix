{
  # The platforms supported.
  supportedSystems ? [
    "aarch64-linux"
    "x86_64-linux"
  ],

  # The system evaluating this expression.
  evalSystem ? builtins.currentSystem or "x86_64-linux",

  # Whether to apply hydraJob to each derivation.
  scrubJobs ? true,

  # The path to Nixpkgs.
  nixpkgs ? null,
}@args:
let

  # A self-reference to this flake, so a jobset file can be evaluated by
  # Hydra as a plain Nix expression and still see the flake's outputs.
  self = builtins.getFlake "git+file://${toString ../.}";

  # Default values do not make unsupplied arguments present; they only make
  # the variable available in scope.
  nixpkgs = args.nixpkgs or self.inputs.nixpkgs-unstable.outPath;

  inherit (self.inputs.nixpkgs-lib) lib;

in
{

  inherit
    lib
    nixpkgs
    self
    ;

  releaseLib = import (nixpkgs + "/pkgs/top-level/release-lib.nix") {
    inherit
      scrubJobs
      supportedSystems
      ;
    system = evalSystem;
    # Passing nixpkgsArgs replaces release-lib's default wholesale, so every
    # setting it carries is restated here.
    nixpkgsArgs = {
      # release-lib forbids lib.fileset by default (Nix issue 11503, chroot
      # stores); packages in this repo's overlay may use it.
      __allowFileset = true;
      config = {
        # By default, Nixpkgs allows aliases. Setting them to false allows us
        # to detect breakages sooner rather than later.
        allowAliases = false;
        allowUnfree = true;
        inHydra = true;
      };
      overlays = [
        self.overlays.default
      ];
    };
  };

}
