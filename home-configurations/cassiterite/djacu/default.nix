{
  system = "x86_64-linux";
  release = "2405";
  modules = [
    {
      home.stateVersion = "24.05";

      theonecfg.users.djacu.enable = true;
      theonecfg.users.djacu.dev.enable = true;
      theonecfg.users.djacu.desktop.enable = true;

      theonecfg.home.programs.agenix.enable = true;
      theonecfg.home.programs.messaging.enable = true;
    }
  ];
}
