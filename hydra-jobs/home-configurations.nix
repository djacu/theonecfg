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
    self
    ;

  inherit (lib.attrsets)
    filterAttrs
    mapAttrs
    ;

  inherit (lib.customisation)
    hydraJob
    ;

  inherit (lib.lists)
    elem
    ;

  # Every homeConfiguration whose system is supported.
  homes = filterAttrs (
    _: value: elem value.config.nixpkgs.system supportedSystems
  ) self.homeConfigurations;

in
# Same <name>.<system> shape release-lib's mapTestOn produces.
mapAttrs (_: value: {
  ${value.config.nixpkgs.system} = hydraJob value.activationPackage;
}) homes
