inputs: {
  release = rec {
    number = "unstable";
    nixpkgs = inputs."nixpkgs-${number}";
  };
  modules =
    {
      config,
      lib,
      pkgs,
      theonecfg,
      ...
    }:
    {
      imports = [
        ./disko.nix
        ./hardware.nix
        ./impermanence.nix

        theonecfg.nixosHardware.framework-intel-core-ultra-series3
      ];
      config = {
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "26.05";

        boot.kernelPackages = pkgs.linuxPackages_6_18;
        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.efi.efiSysMountPoint = "/boot";
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.devNodes = "/dev/disk/by-id";
        # Kept true for parity with the other hosts. Recovery from an unclean
        # pool is zfs_force=1 from the systemd-boot editor, which is enabled.
        boot.zfs.forceImportRoot = true;

        boot.initrd.systemd.services.rollback-root = {
          description = "Rollback ZFS root to empty snapshot";
          wantedBy = [ "initrd.target" ];
          after = [ "zfs-import-zroot.service" ];
          before = [ "sysroot.mount" ];
          unitConfig.DefaultDependencies = "no";
          serviceConfig.Type = "oneshot";
          path = [ config.boot.zfs.package ];
          script = ''
            zfs rollback -r zroot/local/root@empty && echo "rollback of zroot complete"
          '';
        };

        hardware.bluetooth.enable = true;

        # Panther Lake is xe-only. nixos-hardware's shared Intel GPU module
        # still defaults to i915 in the initrd and installs both VAAPI
        # drivers; the Lunar Lake module makes the same two overrides.
        hardware.intelgpu.driver = "xe";
        hardware.intelgpu.vaapiDriver = "intel-media-driver";

        networking.hostId = lib.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

        security.sudo.extraConfig = ''
          # rollback results in sudo lectures after each reboot
          Defaults lecture = never
        '';

        services.zfs.autoScrub.enable = true;

        time.timeZone = "America/Los_Angeles";

        users.mutableUsers = false;
        users.users.root.hashedPassword = "$6$efX.JpKjAey2jrYG$kOt..AuFrPPIVTDncVj7vNkIo4MR/9mYG2SaDV2xpSNDEmk8DRxVNmuMI6hcW.CmD6ZDqdIKCj2MAyHnIdrkl/";

        theonecfg.profiles.common.enable = true;
        theonecfg.profiles.desktop.enable = true;

        theonecfg.users.djacu.enable = true;
        users.users.djacu.hashedPassword = "$6$2rwKYZ9BS2cMhZgH$8gq493fkRqJbunY3BnnGTe9Xq4VTEV5u9acyeAEpFZ6yZ1IM9bIkIsHQm3E2l7oHj0NzZw9FdlEEGGK25YMan/";
      };
    };
}
