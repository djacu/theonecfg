{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkBefore
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.programs.niri;

  # niri's shipped config, minus the one line that starts a bar this setup
  # does not install. The grep makes the build fail if that line changes.
  defaultConfig = pkgs.runCommand "niri-default-config.kdl" { } ''
    src=${pkgs.niri.src}/resources/default-config.kdl
    grep -qx 'spawn-at-startup "waybar"' "$src"
    grep -vx 'spawn-at-startup "waybar"' "$src" > $out
  '';

in
{

  options.theonecfg.programs.niri.enable = mkEnableOption "niri config";

  config = mkIf cfg.enable {

    # The NixOS module installs the session units and the portals.
    wayland.windowManager.niri = {
      enable = true;
      package = pkgs.niri;
      portalPackage = null;
      systemd.enable = false;
    };

    # niri's default key bindings are used unchanged. The binds below keep
    # the default keys and only repoint the ones whose default program is not
    # installed here.
    wayland.windowManager.niri.extraConfig = lib.mkMerge [
      (mkBefore ''
        include "${defaultConfig}"
      '')
      ''
        input {
            // niri's own handling calls a plain suspend, which never
            // hibernates. logind handles the key instead.
            disable-power-key-handling
        }

        cursor {
            xcursor-theme "Adwaita"
            xcursor-size 24
        }

        binds {
            Mod+T hotkey-overlay-title="Open a Terminal: kitty" { spawn "kitty"; }
            Mod+D hotkey-overlay-title="Run an Application: Noctalia" { spawn "noctalia" "msg" "panel-toggle" "launcher"; }
            // Allowed while locked: if the lock screen's process dies, niri
            // stays locked with no prompt, and locking again brings it back.
            Super+Alt+L allow-when-locked=true hotkey-overlay-title="Lock the Screen: Noctalia" { spawn "noctalia" "msg" "session" "lock"; }

            XF86AudioRaiseVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-up"; }
            XF86AudioLowerVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-down"; }
            XF86AudioMute        allow-when-locked=true { spawn "noctalia" "msg" "volume-mute"; }
            XF86AudioMicMute     allow-when-locked=true { spawn "noctalia" "msg" "mic-mute"; }

            XF86AudioPlay        allow-when-locked=true { spawn "noctalia" "msg" "media" "toggle"; }
            XF86AudioStop        allow-when-locked=true { spawn "noctalia" "msg" "media" "stop"; }
            XF86AudioPrev        allow-when-locked=true { spawn "noctalia" "msg" "media" "previous"; }
            XF86AudioNext        allow-when-locked=true { spawn "noctalia" "msg" "media" "next"; }

            XF86MonBrightnessUp   allow-when-locked=true { spawn "noctalia" "msg" "brightness-up"; }
            XF86MonBrightnessDown allow-when-locked=true { spawn "noctalia" "msg" "brightness-down"; }
        }

        // From Noctalia's niri setup notes: its settings window floats, and
        // its notification actions may activate windows.
        window-rule {
            match app-id="dev.noctalia.Noctalia"
            open-floating true
            default-column-width { fixed 1080; }
            default-window-height { fixed 920; }
        }

        debug {
            honor-xdg-activation-with-invalid-serial
        }
      ''
    ];

    # Also in the session environment: a Noctalia started by systemd, and the
    # apps its launcher starts, do not see niri's cursor block.
    home.pointerCursor = {
      enable = true;
      package = pkgs.adwaita-icon-theme;
      name = "Adwaita";
      size = 24;
    };

    home.packages = [ pkgs.wl-mirror ];

  };

}
