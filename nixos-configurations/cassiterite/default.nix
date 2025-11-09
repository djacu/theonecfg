{
  release = "2411";
  modules =
    {
      config,
      pkgs,
      theonecfg,
      ...
    }:
    {
      imports = [
        ./disko.nix
        ./hardware.nix
        ./impermanence.nix

        theonecfg.nixosHardware.lenovo-thinkpad-t480
      ];
      config = {
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "24.05";

        boot.kernelPackages = theonecfg.library.zfs.latestKernelPackage { inherit config pkgs; };
        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.efi.efiSysMountPoint = "/boot";
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.devNodes = "/dev/disk/by-id";

        hardware.bluetooth.enable = true;

        networking.hostId = "abc0862c";

        security.sudo.extraConfig = ''
          # rollback results in sudo lectures after each reboot
          Defaults lecture = never
        '';

        services.zfs.autoScrub.enable = true;

        time.timeZone = "America/Los_Angeles";

        users.mutableUsers = false;
        users.users.root.initialHashedPassword = "$6$efX.JpKjAey2jrYG$kOt..AuFrPPIVTDncVj7vNkIo4MR/9mYG2SaDV2xpSNDEmk8DRxVNmuMI6hcW.CmD6ZDqdIKCj2MAyHnIdrkl/";

        theonecfg.common.enable = true;
        theonecfg.basicNetwork.enable = true;
        theonecfg.desktop.enable = true;

        theonecfg.users.djacu.enable = true;
        users.users.djacu.initialHashedPassword = "$6$XfxMt044Az$jyfPvBMkcpPN.s9ZiVQyBjnU5g3x2cFZjBO3okgTENI2YjP6XokJr7QIaREPIcXiS4z5N9HnavEJEk.tneT670";
      };
    };
}
