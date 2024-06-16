{ config, inputs, ... }:
{
  imports = [
    ./disko.nix
    ./hardware.nix
    ./impermanence.nix

    inputs.nixos-hardware.nixosModules.framework-11th-gen-intel
  ];
  config = {
    nixpkgs.hostPlatform = "x86_64-linux";
    system.stateVersion = "24.05";

    boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.loader.efi.efiSysMountPoint = "/boot";
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.devNodes = "/dev/disk/by-id";

    networking.hostId = "76b05211";

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
    users.users.djacu.initialHashedPassword = "$6$zo7JRVBVVKUVn047$IbDRNzWNcp1hwO2jFGnH9PbGYh2fwDP52zc1/ggMovCYiuMg7N2d7NcCkAr8//Yc6s66D4/tzt8BuuM1Nap3F1";
  };
}
