inputs:
builtins.listToAttrs (
  map (system: {
    name = system;
    value =
      let
        pkgs = inputs.self.legacyPackages.${system};
      in
      {
        inherit (pkgs.theonecfg) nom-check;
      };
  }) (builtins.attrNames inputs.self.legacyPackages)
)
