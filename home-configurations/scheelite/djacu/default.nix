inputs: {
  system = "x86_64-linux";
  release = rec {
    number = "unstable";
    nixpkgs = inputs."nixpkgs-${number}";
    home-manager = inputs."home-manager-${number}";
  };
  modules = [
    {

      home.stateVersion = "24.05";

      theonecfg.users.djacu.enable = true;

      theonecfg.users.djacu.profiles.common.enable = true;
      theonecfg.users.djacu.profiles.developer.enable = true;

    }
  ];
}
