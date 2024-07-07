inputs:
let
  inherit (inputs.nixpkgs-unstable.lib)
    flatten
    filterAttrs
    mapAttrsToList
    nameValuePair
    ;

  inherit (builtins) listToAttrs readDir;
in
listToAttrs (
  flatten (
    mapAttrsToList (
      hostName: _:
      mapAttrsToList (
        userName: _:
        let
          inherit (import ./${hostName}/${userName}) system modules release;
        in
        nameValuePair "${hostName}-${userName}" (
          inputs."home-manager-${release}".lib.homeManagerConfiguration {
            pkgs = import inputs."nixpkgs-${release}" {
              inherit system;
              overlays = [
                inputs.self.overlays.default
                inputs.self.overlays.${release}
              ];
            };
            modules =
              [
                #externals
                inputs."agenix-${release}".homeManagerModules.default
              ]
              ++ [
                # internals
                inputs.self.homeModules.${userName}
              ]
              ++ modules; # configs
            extraSpecialArgs = {
              inherit inputs system;
            };
          }
        )
      ) (filterAttrs (_: fileType: fileType == "directory") (readDir ./${hostName}))
    ) (filterAttrs (_: fileType: fileType == "directory") (readDir ./.))
  )
)
