inputs:
let

  # inherits

  inherit (inputs.self)
    library
    theonecfg
    ;

  inherit (library.systems)
    defaultSystems
    ;

  inherit (theonecfg)
    knownHosts
    ;

  inherit (builtins)
    throw
    ;

  inherit (inputs.nixpkgs-lib)
    lib
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

  inherit (lib.trivial)
    const
    ;

in

{

  homeConfigs = defaultSystems (
    system:
    mapAttrs (const (value: value.activation-script)) (
      filterAttrs (const (value: value.config.nixpkgs.system == system)) inputs.self.homeConfigurations
    )
  );

  systemConfigs = defaultSystems (
    system:
    mapAttrs
      (
        name: value:
        let
          type = knownHosts.${name}.type;
          elemType = elem type;
        in
        hydraJob (
          if
            elemType [
              "desktop"
              "laptop"
              "server"
            ]
          then
            value.config.system.build.toplevel
          else if
            elemType [
              "virtual"
            ]
          then
            value.config.system.build.vm
          else
            throw "NixOS configuration '${name}' has an unknown type '${type}'."
        )
      )
      (
        filterAttrs (const (
          value: value.config.nixpkgs.buildPlatform.system == system
        )) inputs.self.nixosConfigurations
      )
  );

}
