inputs:

let

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    attrNames
    genAttrs
    ;

  inherit (lib.lists)
    elem
    ;

  inherit (inputs.self.library.path)
    getDirectoryNames
    ;

  inherit (inputs.self.theonecfg)
    knownHosts
    ;

in

genAttrs (getDirectoryNames ./.) (
  host:
  let
    hostInfo = import ./${host} inputs;
  in
  hostInfo.release.nixpkgs.lib.nixosSystem {
    modules = [
      (
        { config, ... }:
        {
          assertions = [
            {
              assertion = elem config.networking.hostName (attrNames knownHosts);
              message = "Hostname is not known!";
            }
          ];
          networking.hostName = host;
        }
      )
      inputs.self.nixosModules.default
      hostInfo.modules
    ];

    specialArgs = {
      inherit (inputs.self) theonecfg;
    };
  }
)
