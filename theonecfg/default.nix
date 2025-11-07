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

}
