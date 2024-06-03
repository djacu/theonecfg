let
  knownConfigurations = [ "test-vm" ];
in
inputs:
builtins.mapAttrs
  (
    hostDirectory: _:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        (
          { config, ... }:
          {
            assertions = [
              {
                assertion = builtins.elem config.networking.hostName knownConfigurations;
                message = "Hostname is not known!";
              }
            ];
            networking.hostName = hostDirectory;
          }
        )
        inputs.self.nixosModules.default
        ./${hostDirectory}
      ];
    }
  )
  (
    inputs.nixpkgs.lib.attrsets.filterAttrs (_: fileType: fileType == "directory") (
      builtins.readDir ./.
    )
  )
