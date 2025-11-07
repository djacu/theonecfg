let
  knownConfigurations = [
    "argentite"
    "malachite"
    "cassiterite"
    "scheelite"
    "test-vm"
  ];
in
inputs:
builtins.mapAttrs (
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
      inherit (inputs.self) theonecfg;
    };
  }
) (inputs.self.library.path.getDirectories ./.)
