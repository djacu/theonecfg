{
  system = "x86_64-linux";
  release = "2505";
  modules = [
    {
      home.stateVersion = "25.05";

      theonecfg.users.djacu.enable = true;

      theonecfg.users.djacu.desktop.enable = true;
      theonecfg.users.djacu.dev.enable = true;
      theonecfg.users.djacu.nix.enable = true;

      theonecfg.home.programs.messaging.enable = true;
    }
  ];
}
