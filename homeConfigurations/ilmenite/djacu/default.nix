inputs: {
  system = "x86_64-linux";
  release = rec {
    number = "unstable";
    nixpkgs = inputs."nixpkgs-${number}";
    home-manager = inputs."home-manager-${number}";
  };
  modules = [
    {

      home.stateVersion = "26.05";

      theonecfg.users.djacu.enable = true;

      theonecfg.users.djacu.profiles.common.enable = true;
      theonecfg.users.djacu.profiles.desktop.enable = true;
      theonecfg.users.djacu.profiles.developer.enable = true;

      theonecfg.programs.niri.enable = true;
      theonecfg.programs.noctalia.enable = true;

      # Per-monitor settings. External monitors are matched by manufacturer,
      # model and serial so they follow the monitor across ports; the laptop
      # panel has no serial and is matched by its connector. The Samsung name
      # is the expected form from its EDID and is to be confirmed against
      # `niri msg outputs`.
      wayland.windowManager.niri.extraConfig = ''
        output "eDP-1" {
            scale 1.7
            layout {
                preset-column-widths {
                    proportion 0.5
                    proportion 0.66667
                    proportion 1.0
                }
            }
        }

        output "Samsung Electric Company Odyssey G95NC HNTY301614" {
            scale 1.0
            layout {
                preset-column-widths {
                    proportion 0.25
                    proportion 0.33333
                    proportion 0.5
                }
            }
        }
      '';

    }
  ];
}
