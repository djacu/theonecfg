{
  # The platforms supported. Live images are x86_64 only today.
  supportedSystems ? [ "x86_64-linux" ],

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

  inherit (self.theonecfg)
    knownHosts
    ;

  # Every nixosConfiguration of type live whose build platform is supported.
  liveHosts = filterAttrs (
    name: value:
    knownHosts.${name}.type == "live" && elem value.config.nixpkgs.buildPlatform.system supportedSystems
  ) self.nixosConfigurations;

in
# Same <name>.<system> shape release-lib's mapTestOn produces.
mapAttrs (_: value: {
  ${value.config.nixpkgs.buildPlatform.system} = hydraJob value.config.system.build.isoImage;
}) liveHosts
