inputs:

let

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    mapAttrs
    ;

  inherit (lib.trivial)
    const
    flip
    ;

  inherit (inputs)
    self
    ;

  inherit (inputs.self)
    formatterModule
    legacyPackages
    ;

in

mapAttrs (flip (
  const (system: {

    formatting = formatterModule.${system}.config.build.check self;

  })
)) legacyPackages
