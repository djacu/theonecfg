inputs: {

  inherit (inputs.self) library;

  knownHosts = [
    "argentite"
    "malachite"
    "cassiterite"
    "scheelite"
    "test-vm"
  ];

  knownUsers = {
    djacu = {
      uid = 1000;
    };
  };

  nixosHardware = {
    inherit (inputs.nixos-hardware.nixosModules)
      framework-11th-gen-intel
      lenovo-thinkpad-t480
      ;
  };

}
