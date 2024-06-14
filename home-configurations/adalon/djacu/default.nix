{
  system = "x86_64-linux";
  modules = [
    {
      home.stateVersion = "24.05";

      theonecfg.users.djacu.enable = true;
      theonecfg.users.djacu.dev.enable = true;
      #theonecfg.users.djacu.desktop.enable = true;
    }
  ];
}
