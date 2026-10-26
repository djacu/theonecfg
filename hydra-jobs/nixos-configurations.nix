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

  inherit (self.theonecfg)
    knownHosts
    ;

  # Every nixosConfiguration whose build platform is supported.
  hosts = filterAttrs (
    _: value: elem value.config.nixpkgs.buildPlatform.system supportedSystems
  ) self.nixosConfigurations;

  # What a host of each knownHosts type builds.
  build =
    name: value:
    let
      type = knownHosts.${name}.type;
    in
    if
      elem type [
        "desktop"
        "laptop"
        "server"
      ]
    then
      value.config.system.build.toplevel
    else if type == "virtual" then
      value.config.system.build.vm
    else if type == "live" then
      value.config.system.build.isoImage
    else
      throw "NixOS configuration '${name}' has an unknown type '${type}'.";

in
# Same <name>.<system> shape release-lib's mapTestOn produces.
mapAttrs (name: value: {
  ${value.config.nixpkgs.buildPlatform.system} = hydraJob (build name value);
}) hosts
