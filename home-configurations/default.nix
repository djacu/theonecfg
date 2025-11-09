inputs:
let

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    genAttrs'
    mergeAttrsList
    ;

  inherit (lib.lists)
    map
    ;

  inherit (lib.trivial)
    pipe
    ;

  inherit (inputs.self.library.path)
    getDirectoryNames
    ;

  mkUsersForHost =
    host:
    genAttrs' (getDirectoryNames ./${host}) (user: {
      name = host + "-" + user;
      value =
        let
          inherit (import ./${host}/${user}) system modules release;
        in
        inputs."home-manager-${release}".lib.homeManagerConfiguration {
          pkgs = import inputs."nixpkgs-${release}" {
            inherit system;
            overlays = [ inputs.self.overlays.default ];
          };
          modules = [ inputs.self.homeModules.${user} ] ++ modules;
          extraSpecialArgs = {
            inherit inputs;
            inherit (inputs.self) theonecfg;
          };
        };
    });

in

pipe ./. [
  getDirectoryNames
  (map mkUsersForHost)
  mergeAttrsList
]
