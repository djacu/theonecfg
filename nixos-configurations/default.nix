let
  knownConfigurations = [
    "adalon"
    "gildenfire"
    "test-vm"
  ];
in
inputs:
builtins.mapAttrs
  (
    hostDirectory: _:
    let
      inherit (import ./${hostDirectory}) release modules;
    in
    inputs."nixpkgs-${release}".lib.nixosSystem {
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
        modules
      ];

      specialArgs = {
        inherit inputs;
      };
    }
  )
  (
    inputs.nixpkgs-unstable.lib.attrsets.filterAttrs (_: fileType: fileType == "directory") (
      builtins.readDir ./.
    )
  )
