{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkBefore
    mkForce
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.programs.niri;

  # niri's shipped config, minus the line that starts a bar this setup does
  # not install and the Ctrl+Alt+Delete bind that quits the session. niri
  # has no way to unbind a key, only to replace it, so the line is removed
  # here. The greps make the build fail if either line changes.
  defaultConfig = pkgs.runCommand "niri-default-config.kdl" { } ''
    src=${pkgs.niri.src}/resources/default-config.kdl
    grep -qx 'spawn-at-startup "waybar"' "$src"
    grep -qx '    Ctrl+Alt+Delete { quit; }' "$src"
    grep -vx -e 'spawn-at-startup "waybar"' -e '    Ctrl+Alt+Delete { quit; }' "$src" > $out
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
            // niri's default quits the session after a confirmation. Open
            // Noctalia's session menu instead, so no key logs out directly.
            Mod+Shift+E hotkey-overlay-title="Session Menu: Noctalia" { spawn "noctalia" "msg" "panel-toggle" "session"; }
            // Clipboard history on Super+V, as on other desktops (owner's
            // choice). niri's two floating actions move up one modifier.
            // All three are toggles, so they do not repeat while held.
            Mod+V repeat=false hotkey-overlay-title="Clipboard History: Noctalia" { spawn "noctalia" "msg" "panel-toggle" "clipboard"; }
            Mod+Shift+V repeat=false { toggle-window-floating; }
            Mod+Ctrl+V repeat=false { switch-focus-between-floating-and-tiling; }

            // The Framework's F9 "display" key sends Super+P, which niri
            // leaves unbound. Keep-awake suspends the idle timers, for
            // presenting. repeat=false: a toggle that repeats while the key
            // is held switches itself straight back off.
            Mod+P repeat=false hotkey-overlay-title="Toggle Keep-Awake: Noctalia" { spawn "noctalia" "msg" "caffeine-toggle"; }

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

    # The GTK passphrase prompt matches the other windows in this session;
    # pinentry-qt has no theme without Plasma. It draws through GNOME's
    # prompt service, which the NixOS niri module registers along with
    # gnome-keyring; the Plasma hosts lack it, so the shared gpg module
    # keeps pinentry-qt and this overrides it for niri only.
    services.gpg-agent.pinentry.package = mkForce pkgs.pinentry-gnome3;

    # libnotify for notify-send, which used to come in with Plasma.
    # wl-clipboard gives command-line programs (gh, scripts) wl-copy and
    # wl-paste; graphical apps and OSC 52 in kitty do not need it.
    home.packages = [
      pkgs.libnotify
      pkgs.wl-clipboard
      pkgs.wl-mirror
    ];

  };

}
