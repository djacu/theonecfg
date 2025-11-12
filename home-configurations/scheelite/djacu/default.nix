{
  system = "x86_64-linux";
  release = "2505";
  modules = [
    {

      home.stateVersion = "24.05";

      theonecfg.users.djacu.enable = true;

      theonecfg.users.djacu.profiles.common.enable = true;
      theonecfg.users.djacu.profiles.developer.enable = true;

    }
  ];
}
