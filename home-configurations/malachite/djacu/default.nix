inputs: {
  system = "x86_64-linux";
  release = rec {
    number = "2505";
    nixpkgs = inputs."nixpkgs-${number}";
    home-manager = inputs."home-manager-${number}";
  };
  modules = [
    {

      home.stateVersion = "24.05";

      theonecfg.users.djacu.enable = true;

      theonecfg.users.djacu.profiles.common.enable = true;
      theonecfg.users.djacu.profiles.desktop.enable = true;
      theonecfg.users.djacu.profiles.developer.enable = true;

    }
  ];
}
