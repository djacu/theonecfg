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
          hostUserInfo = import ./${host}/${user} inputs;
        in
        hostUserInfo.release.home-manager.lib.homeManagerConfiguration {
          pkgs = import hostUserInfo.release.nixpkgs {
            inherit (hostUserInfo) system;
            overlays = [ inputs.self.overlays.default ];
          };
          modules = [ inputs.self.homeModules.${user} ] ++ hostUserInfo.modules;
          extraSpecialArgs = {
            theonecfg = inputs.self.theonecfg // {
              inherit (hostUserInfo) release;
            };
          };
        };
    });

in

pipe ./. [
  getDirectoryNames
  (map mkUsersForHost)
  mergeAttrsList
]
