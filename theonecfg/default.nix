inputs: {

  inherit (inputs.self) library;

  knownHosts = [
    "argentite"
    "malachite"
    "cassiterite"
    "scheelite"
    "test-vm"
  ];

  knownUsers = [
    "djacu"
  ];

  nixosHardware = {
    inherit (inputs.nixos-hardware.nixosModules)
      framework-11th-gen-intel
      lenovo-thinkpad-t480
      ;
  };

}
