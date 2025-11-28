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
          hostUserInfo = import ./${host}/${user};
        in
        inputs."home-manager-${hostUserInfo.release}".lib.homeManagerConfiguration {
          pkgs = import inputs."nixpkgs-${hostUserInfo.release}" {
            inherit (hostUserInfo) system;
            overlays = [ inputs.self.overlays.default ];
          };
          modules = [ inputs.self.homeModules.${user} ] ++ hostUserInfo.modules;
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
