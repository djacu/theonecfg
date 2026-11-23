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
      ...
    }:
    {
      imports = [
        ./disko.nix
        ./hardware.nix
        ./impermanence.nix
      ];
      config = {
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "25.05";

        boot.kernelPackages = pkgs.linuxPackages_6_18;
        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.efi.efiSysMountPoint = "/boot";
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.devNodes = "/dev/disk/by-id";
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

        networking.hostId = lib.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

        security.sudo.extraConfig = ''
          # rollback results in sudo lectures after each reboot
          Defaults lecture = never
        '';

        services.zfs.autoScrub.enable = true;

        # The KVM exposes its built-in C-Media sound chip (0d8c:0016) behind
        # its own "Virtual HUB" (09ea:0130). After every host reboot the chip
        # enumerates but answers no audio-class control request (-110
        # timeouts), which leaves wireplumber in uninterruptible sleep and
        # stalls everything that enumerates audio, Firefox first. Neither a
        # re-enumeration nor cutting power to the hub port clears it; only a
        # power cut to the KVM itself does. The passthrough is unused, so keep
        # the kernel from configuring the device at all. The keyboard, mouse
        # and virtual HID behind the same hub are unaffected. Issue #24.
        services.udev.extraRules = ''
          ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0d8c", ATTR{idProduct}=="0016", ATTRS{idVendor}=="09ea", ATTRS{idProduct}=="0130", ATTR{authorized}="0"
        '';

        time.timeZone = "America/Los_Angeles";

        users.mutableUsers = false;
        users.users.root.initialHashedPassword = "$6$efX.JpKjAey2jrYG$kOt..AuFrPPIVTDncVj7vNkIo4MR/9mYG2SaDV2xpSNDEmk8DRxVNmuMI6hcW.CmD6ZDqdIKCj2MAyHnIdrkl/";

        theonecfg.hardware.nvidia-1080ti.enable = true;
        theonecfg.profiles.common.enable = true;
        theonecfg.profiles.desktop.enable = true;

        theonecfg.users.djacu.enable = true;
        users.users.djacu.initialHashedPassword = "$6$TI48LHPoldY069pW$YTQAaocNJcn9dmt5dmyHkhy.wuWjYwoMqTcwgfGlOEAFRZ/vQMM565zE.xZB.dL7pTRZn71zjv9lAeW4YAoq40";
      };
    };
}
