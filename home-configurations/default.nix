inputs:
let
  inherit (inputs.nixpkgs.lib)
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
          inherit (import ./${hostName}/${userName}) system modules;
        in
        nameValuePair "${hostName}-${userName}" (
          inputs.home-manager.lib.homeManagerConfiguration {
            pkgs = import inputs.nixpkgs { inherit system; };
            modules = [ inputs.self.homeModules.${userName} ] ++ modules;
          }
        )
      ) (filterAttrs (_: fileType: fileType == "directory") (readDir ./${hostName}))
    ) (filterAttrs (_: fileType: fileType == "directory") (readDir ./.))
  )
)
