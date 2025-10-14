{
  release = "2505";
  modules =
    {
      config,
      inputs,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        ./disko.nix
        ./hardware.nix
        ./impermanence.nix

        inputs.nixos-hardware.nixosModules.framework-11th-gen-intel
      ];
      config = {
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "25.05";

        boot.kernelPackages = pkgs.linuxPackages_6_15;
        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.efi.efiSysMountPoint = "/boot";
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.devNodes = "/dev/disk/by-id";

        hardware.bluetooth.enable = true;

        networking.hostId = lib.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

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
        users.users.djacu.initialHashedPassword = "$6$TI48LHPoldY069pW$YTQAaocNJcn9dmt5dmyHkhy.wuWjYwoMqTcwgfGlOEAFRZ/vQMM565zE.xZB.dL7pTRZn71zjv9lAeW4YAoq40";
      };
    };
}
