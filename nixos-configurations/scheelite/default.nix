{
  release = "2405";
  modules =
    { config, lib, ... }:
    {
      imports = [
        ./hardware.nix
        ./impermanence.nix
      ];
      config = {
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "24.05";

        # Use the systemd-boot EFI boot loader.
        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.efi.efiSysMountPoint = "/boot";

        # ZFS
        boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.devNodes = "/dev/disk/by-id";
        services.zfs.autoScrub.enable = true;
        boot.initrd.postDeviceCommands = lib.mkAfter ''
          zfs rollback -r scheelite-root/local/root@empty
        '';

        networking.hostId = lib.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

        security.sudo.extraConfig = ''
          # rollback results in sudo lectures after each reboot
          Defaults lecture = never
        '';

        time.timeZone = "America/Los_Angeles";

        users.mutableUsers = false;
        users.users.root.initialHashedPassword = "$6$efX.JpKjAey2jrYG$kOt..AuFrPPIVTDncVj7vNkIo4MR/9mYG2SaDV2xpSNDEmk8DRxVNmuMI6hcW.CmD6ZDqdIKCj2MAyHnIdrkl/";

        theonecfg.common.enable = true;
        theonecfg.audio.enable = true;
        theonecfg.dev.enable = true;
        theonecfg.fonts.dev.enable = true;
        networking.useDHCP = lib.mkDefault true;

        theonecfg.users.djacu.enable = true;
        users.users.djacu.initialHashedPassword = "$y$j9T$W5JJISgEkrLM1NRu.uGR4/$2GXSsgkFimX46x.h.MqUEiLCuWl9kmV0dJoZtX6e78/";
      };
    };
}
