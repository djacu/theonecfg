inputs: {
  system = "aarch64-linux";
  release = rec {
    number = "2505";
    nixpkgs = inputs."nixpkgs-${number}";
    home-manager = inputs."home-manager-${number}";
  };
  modules = [
    {

      home.stateVersion = "25.05";

      theonecfg.users.djacu.enable = true;

      theonecfg.users.djacu.profiles.common.enable = true;
      theonecfg.users.djacu.profiles.developer.enable = true;

      # discord is broken on aarch64-linux
      # if it ever gets fixed uncomment the desktop profile and remove the rest
      # theonecfg.users.djacu.profiles.desktop.enable = true;
      theonecfg.users.djacu.programs.firefox.enable = true;
      theonecfg.programs.kitty.enable = true;
      # theonecfg.packages.messaging.enable = true;
      theonecfg.packages.productivity.enable = true;

    }
  ];
}
