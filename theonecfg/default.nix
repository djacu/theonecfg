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
    };
  };

  nixosHardware = {
    inherit (inputs.nixos-hardware.nixosModules)
      framework-11th-gen-intel
      lenovo-thinkpad-t480
      ;
  };

  externalModules = {
    disko = inputs.disko.nixosModules.default;
    impermanence = inputs.impermanence.nixosModules.impermanence;
    sops-nix = inputs.sops-nix.nixosModules.sops;
  };

}
