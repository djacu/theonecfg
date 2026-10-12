inputs: {
  release = rec {
    number = "unstable";
    nixpkgs = inputs."nixpkgs-${number}";
  };
  modules =
    {
      config,
      lib,
      modulesPath,
      pkgs,
      ...
    }:
    {
      imports = [
        (modulesPath + "/installer/cd-dvd/iso-image.nix")
        (modulesPath + "/profiles/all-hardware.nix")
      ];
      config = {
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "26.05";

        theonecfg.profiles.yubikey-live.enable = true;

        # iso-image.nix defines image.baseName itself at normal priority.
        image.baseName = lib.mkForce config.networking.hostName;
        isoImage = {
          squashfsCompression = "zstd";
          makeEfiBootable = true;
          makeUsbBootable = true;
          appendToMenuLabel = " YubiKey Live";
        };

        # Who logs in is the host's decision; the profile is user-agnostic
        # so the VM test can import it without the theonecfg registry.
        theonecfg.users.djacu.enable = true;
        users.users.djacu.initialHashedPassword = "";
        users.users.root.initialHashedPassword = "";

        # The desktop lives here, not in the profile, so the VM test stays a
        # console system.
        theonecfg.desktops.plasma.enable = true;
        services.displayManager.autoLogin = {
          enable = true;
          user = "djacu";
        };

        programs.firefox = {
          enable = true;
          preferences = {
            # No data-reporting prompt and no welcome tab on an offline box.
            "datareporting.policy.dataSubmissionEnabled" = false;
            "browser.aboutwelcome.enabled" = false;
          };
          preferencesStatus = "user";
        };

        environment.systemPackages = [
          pkgs.kdePackages.okular
          (pkgs.makeDesktopItem {
            name = "yubikey-guide";
            desktopName = "YubiKey Guide";
            genericName = "Guide to using YubiKey for GnuPG and SSH";
            exec = "view-yubikey-guide";
            categories = [ "Documentation" ];
          })
          (pkgs.makeDesktopItem {
            name = "diceware";
            desktopName = "Diceware Passphrase Generator";
            genericName = "Passphrase Generator";
            exec = "xdg-open http://127.0.0.1:8080/";
            categories = [ "Utility" ];
          })
        ];
      };
    };
}
