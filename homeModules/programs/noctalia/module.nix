{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkAfter
    mkIf
    mkMerge
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.programs.noctalia;

  niriEnabled = config.wayland.windowManager.niri.enable;

  # Noctalia runs an idle command once per idle period, so wait here until
  # the laptop is on battery. systemd-ac-power exits 0 on AC.
  batterySleep = pkgs.writeShellScript "noctalia-battery-sleep" ''
    while ${pkgs.systemd}/bin/systemd-ac-power; do ${pkgs.coreutils}/bin/sleep 30; done
    ${pkgs.systemd}/bin/systemctl suspend-then-hibernate
  '';

  # A read-only local plugin source holding one Nix-pinned plugin. Noctalia
  # scans <source>/<dir>/plugin.toml and takes the plugin's id from that
  # manifest, so the directory name does not matter.
  pluginSource = name: package: {
    inherit name;
    kind = "path";
    location = "${pkgs.linkFarm name { ${name} = package; }}";
    enabled = true;
  };

  # niri accepts one binds block per file but merges binds across included
  # files, so each plugin's key goes into a file of its own.
  niriBinds = name: binds: ''
    include "${pkgs.writeText "niri-${name}-binds.kdl" "binds {\n${binds}\n}\n"}"
  '';

in
{

  options.theonecfg.programs.noctalia = {
    enable = mkEnableOption "noctalia config";
    plugins = {
      screenRecorder.enable = mkEnableOption "the Screen Recorder plugin" // {
        default = true;
      };
      notes.enable = mkEnableOption "the Notes plugin" // {
        default = true;
      };
      timer.enable = mkEnableOption "the Timer plugin" // {
        default = true;
      };
      bitwarden.enable = mkEnableOption "the Bitwarden plugin" // {
        default = true;
      };
      translator.enable = mkEnableOption "the Translator plugin" // {
        default = true;
      };
      kaomoji.enable = mkEnableOption "the Kaomoji plugin" // {
        default = true;
      };
      worldClock.enable = mkEnableOption "the World Clock plugin" // {
        default = true;
      };
    };
    templates = {
      qt.enable = mkEnableOption "Noctalia's colours in Qt apps, through qt5ct" // {
        default = true;
      };
      kitty.enable = mkEnableOption "Noctalia's colours in kitty" // {
        default = true;
      };
      niri.enable = mkEnableOption "Noctalia's colours in niri's borders and focus ring" // {
        default = true;
      };
      btop.enable = mkEnableOption "Noctalia's colours in btop" // {
        default = true;
      };
      gtk.enable = mkEnableOption "Noctalia's colours in GTK 3 and GTK 4 apps" // {
        default = true;
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [

    {

      programs.noctalia = {
        enable = true;
        systemd.enable = true;

        settings = {

          # Off by default. Without an agent in the session, pkexec and other
          # polkit prompts have nothing to ask through and fail.
          shell.polkit_agent = true;

          # Plugins are code Noctalia runs as the user. By default it clones
          # its two GitHub sources and pulls them every 6 hours, unpinned.
          # Each plugin block below declares its own pinned local source, and
          # declaring any source replaces those defaults. auto_update guards
          # against a GitHub source being added back from the GUI. Bump the
          # plugins through the noctalia-dev-official-plugins package.
          plugins.auto_update = "none";

          # Noctalia runs as a systemd user service, and apps started from its
          # launcher land in that service's cgroup. Every restart of Noctalia,
          # including each home-manager switch that changes its config, then
          # kills them all. Start them as their own transient units instead.
          shell.launch_apps_as_systemd_services = true;

          # Noctalia's own suspend is a plain one, which never hibernates.
          shell.session.power.suspend = "${pkgs.systemd}/bin/systemctl suspend-then-hibernate";

          # Noctalia's built-in Nord palette, dark (owner's choice).
          theme = {
            source = "builtin";
            builtin = "Nord";
            mode = "dark";
          };

          idle = {
            behavior_order = [
              "screen-off"
              "lock"
              "battery-sleep"
            ];

            behavior.screen-off = {
              action = "screen_off";
              timeout = 300;
              enabled = true;
            };

            behavior.lock = {
              action = "lock";
              timeout = 600;
              enabled = true;
            };

            # Sleeps on battery only. The waiter runs as a transient unit so
            # the resume command can stop it when activity returns.
            behavior.battery-sleep = {
              action = "command";
              timeout = 600;
              enabled = true;
              command = "${pkgs.systemd}/bin/systemd-run --user --collect --unit=noctalia-battery-sleep ${batterySleep}";
              resume_command = "${pkgs.systemd}/bin/systemctl --user stop noctalia-battery-sleep.service";
            };
          };

        };
      };

      # The unit is wanted by graphical-session.target, which a Plasma session
      # also reaches. Under Plasma (the fallback generation) it would run as a
      # second shell with its idle behaviours armed. Only when niri is the
      # compositor: otherwise this would keep Noctalia from starting at all.
      systemd.user.services.noctalia.Unit.ConditionEnvironment =
        mkIf niriEnabled "XDG_CURRENT_DESKTOP=niri";

    }

    (mkIf cfg.plugins.screenRecorder.enable {
      programs.noctalia.settings.plugins = {
        source = [ (pluginSource "screen_recorder" pkgs.noctalia-official-plugin-screen-recorder) ];
        enabled = [ "noctalia/screen_recorder" ];
      };
      # slurp is for region capture. Region capture reads the screen directly
      # through gpu-screen-recorder's gsr-kms-server, which it runs with
      # pkexec, so each region recording asks for authentication. The NixOS
      # programs.gpu-screen-recorder option would grant that permanently; it
      # is left off to keep this in home-manager. Portal capture never asks.
      home.packages = [
        pkgs.gpu-screen-recorder
        pkgs.slurp
      ];
      wayland.windowManager.niri.extraConfig = mkIf niriEnabled (
        niriBinds "screen-recorder" ''
          Mod+Alt+R repeat=false hotkey-overlay-title="Toggle Screen Recording: Noctalia" { spawn "noctalia" "msg" "plugin" "noctalia/screen_recorder:service" "all" "toggle"; }
          Mod+Alt+Shift+R repeat=false hotkey-overlay-title="Record a Region: Noctalia" { spawn "noctalia" "msg" "plugin" "noctalia/screen_recorder:service" "all" "start" "region"; }
        ''
      );
    })

    (mkIf cfg.plugins.notes.enable {
      programs.noctalia.settings.plugins = {
        source = [ (pluginSource "notes" pkgs.noctalia-official-plugin-notes) ];
        enabled = [ "noctalia/notes" ];
      };
      wayland.windowManager.niri.extraConfig = mkIf niriEnabled (
        niriBinds "notes" ''
          Mod+N repeat=false hotkey-overlay-title="Toggle Notes: Noctalia" { spawn "noctalia" "msg" "panel-toggle" "noctalia/notes:panel"; }
        ''
      );
    })

    (mkIf cfg.plugins.timer.enable {
      programs.noctalia.settings.plugins = {
        source = [ (pluginSource "timer" pkgs.noctalia-official-plugin-timer) ];
        enabled = [ "noctalia/timer" ];
      };
      wayland.windowManager.niri.extraConfig = mkIf niriEnabled (
        niriBinds "timer" ''
          Mod+Alt+T repeat=false hotkey-overlay-title="Toggle Timer: Noctalia" { spawn "noctalia" "msg" "panel-toggle" "noctalia/timer:panel"; }
        ''
      );
    })

    (mkIf cfg.plugins.bitwarden.enable {
      programs.noctalia.settings.plugins = {
        source = [ (pluginSource "bitwarden" pkgs.noctalia-official-plugin-bitwarden) ];
        enabled = [ "noctalia/bitwarden" ];
      };
      home.packages = [ pkgs.bitwarden-cli ];
    })

    (mkIf cfg.plugins.translator.enable {
      programs.noctalia.settings.plugins = {
        source = [ (pluginSource "translator" pkgs.noctalia-official-plugin-translator) ];
        enabled = [ "noctalia/translator" ];
      };
    })

    (mkIf cfg.plugins.kaomoji.enable {
      programs.noctalia.settings.plugins = {
        source = [ (pluginSource "kaomoji" pkgs.noctalia-official-plugin-kaomoji) ];
        enabled = [ "noctalia/kaomoji" ];
      };
    })

    (
      let
        zonesDir = "${config.xdg.stateHome}/noctalia/plugins/data/noctalia/world_clock";
        zones = pkgs.writeText "noctalia-world-clock-zones.json" (
          builtins.toJSON [
            {
              id = "America/Los_Angeles";
              label = "Pacific";
              on_bar = true;
            }
            {
              id = "America/New_York";
              label = "Eastern";
              on_bar = true;
            }
            {
              id = "UTC";
              label = "UTC";
              on_bar = true;
            }
            # Switches between CET and CEST with the EU's daylight saving.
            {
              id = "Europe/Berlin";
              label = "Central Europe";
              on_bar = true;
            }
          ]
        );
      in
      mkIf cfg.plugins.worldClock.enable {
        programs.noctalia.settings = {
          plugins = {
            source = [ (pluginSource "world_clock" pkgs.noctalia-official-plugin-world-clock) ];
            enabled = [ "noctalia/world_clock" ];
          };
          # Plan mode highlights a zone while its local hour is in [start, end).
          plugin_settings."noctalia/world_clock" = {
            working_hours_start = 8;
            working_hours_end = 20;
          };
        };
        # The plugin reads its zones from this file when it starts and
        # rewrites it on every change made in its panel. Replace it on each
        # switch, before Noctalia restarts; the restart trigger makes a change
        # to the list here restart Noctalia so the plugin reads it.
        home.activation.noctaliaWorldClockZones =
          lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "writeBoundary" ]
            ''
              run mkdir -p ${zonesDir}
              run install -m 644 ${zones} ${zonesDir}/zones.json
            '';
        systemd.user.services.noctalia.Unit.X-Restart-Triggers = [ "${zones}" ];
        wayland.windowManager.niri.extraConfig = mkIf niriEnabled (
          niriBinds "world-clock" ''
            Mod+C repeat=false hotkey-overlay-title="Toggle World Clock: Noctalia" { spawn "noctalia" "msg" "panel-toggle" "noctalia/world_clock:panel"; }
            // niri's default for Mod+C, moved up one modifier.
            Mod+Shift+C { center-column; }
          ''
        );
      }
    )

    # Noctalia's built-in "qt" template writes its palette as a qt5ct and a
    # qt6ct colour scheme. The qt5ct platform theme applies it to Qt 5 apps,
    # and qt6ct answers to the same name for Qt 6 apps. Both only watch their
    # top directory, so an open app keeps its colours until restarted.
    (mkIf cfg.templates.qt.enable {
      programs.noctalia.settings.theme.templates.builtin_ids = [ "qt" ];
      qt = {
        enable = true;
        platformTheme.name = "qtct";
        qt5ctSettings.Appearance = {
          custom_palette = true;
          color_scheme_path = "${config.xdg.configHome}/qt5ct/colors/noctalia.conf";
        };
        qt6ctSettings.Appearance = {
          custom_palette = true;
          color_scheme_path = "${config.xdg.configHome}/qt6ct/colors/noctalia.conf";
        };
      };
    })

    # Noctalia writes ~/.config/kitty/themes/noctalia.conf and reloads kitty.
    # Its hook appends this exact line to kitty.conf when it is missing, which
    # fails on home-manager's read-only file, so it is declared here. It comes
    # after the kitty module's theme, so these colours win.
    (mkIf (cfg.templates.kitty.enable && config.programs.kitty.enable) {
      programs.noctalia.settings.theme.templates.builtin_ids = [ "kitty" ];
      programs.kitty.extraConfig = "include themes/noctalia.conf";
    })

    # Noctalia writes ~/.config/niri/noctalia.kdl: focus ring, border and tab
    # colours. Its hook appends an include to config.kdl when there is none,
    # which fails on the read-only file, so it is declared here, last, so its
    # colours win. optional: niri only warns until Noctalia has written it.
    (mkIf (cfg.templates.niri.enable && niriEnabled) {
      programs.noctalia.settings.theme.templates.builtin_ids = [ "niri" ];
      wayland.windowManager.niri.extraConfig = mkAfter ''
        include optional=true "${config.xdg.configHome}/niri/noctalia.kdl"
      '';
    })

    # Noctalia writes ~/.config/btop/themes/noctalia.theme. btop.conf comes
    # from home-manager, so the theme is selected here and the hook, finding
    # it selected, only reloads btop.
    (mkIf (cfg.templates.btop.enable && config.programs.btop.enable) {
      programs.noctalia.settings.theme.templates.builtin_ids = [ "btop" ];
      programs.btop.settings.color_theme = "noctalia";
    })

    # Noctalia writes noctalia.css for GTK 3 and GTK 4. The colour names it
    # sets are libadwaita's, which GTK 3 apps only use under the adw-gtk3
    # theme; GTK 4 apps need only the import. The hook adds the import to
    # gtk.css when it is missing and replaces a read-only gtk.css with its
    # own file, so the import is declared here.
    (mkIf cfg.templates.gtk.enable {
      programs.noctalia.settings.theme.templates.builtin_ids = [
        "gtk3"
        "gtk4"
      ];
      gtk = {
        enable = true;
        # No GTK 2 apps here.
        gtk2.enable = false;
        theme = {
          name = "adw-gtk3-dark";
          package = pkgs.adw-gtk3;
        };
        gtk3.extraCss = ''@import url("noctalia.css");'';
        gtk4.extraCss = ''@import url("noctalia.css");'';
      };
    })

  ]);

}
