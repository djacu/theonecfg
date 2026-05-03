inputs: {

  inherit (inputs.self) library;

  knownHosts = {
    argentite = {
      type = "desktop";
      forwardAgent = true;
    };
    cassiterite = {
      type = "laptop";
      forwardAgent = true;
    };
    malachite = {
      type = "laptop";
      forwardAgent = true;
    };
    scheelite = {
      type = "server";
      forwardAgent = true;
    };
    test-vm = {
      type = "virtual";
      forwardAgent = false;
    };
  };

  knownUsers = {
    djacu = {
      uid = 1000;
      name = "Daniel Baker";
      email = "dan@djacu.dev";
      username = "djacu";
    };
  };

  nixosHardware = {
    inherit (inputs.nixos-hardware.nixosModules)
      framework-11th-gen-intel
      lenovo-thinkpad-t480
      ;
  };

}
