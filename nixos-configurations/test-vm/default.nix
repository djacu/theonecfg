inputs: {
  release = rec {
    number = "2505";
    nixpkgs = inputs."nixpkgs-${number}";
  };
  modules =
    { modulesPath, ... }:
    {
      imports = [
        #(modulesPath + "/profiles/graphical.nix")
        (modulesPath + "/profiles/qemu-guest.nix")
      ];

      system.stateVersion = "24.05";

      nixpkgs.hostPlatform = "x86_64-linux";

      boot.loader.grub.devices = [ "/dev/sda" ];
      fileSystems = {
        "/".device = "/dev/hda1";
      };

      theonecfg.profiles.simple-vm.enable = true;
      theonecfg.profiles.common.enable = true;
    };
}
