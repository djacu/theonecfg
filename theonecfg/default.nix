inputs: {

  inherit (inputs.self) library;

  knownHosts = {
    argentite = {
      type = "desktop";
      forwardAgent = true;
    };
    bauxite = {
      type = "laptop";
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
    x13s-iso = {
      type = "iso";
      forwardAgent = false;
    };
  };

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
