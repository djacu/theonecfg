{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    mkOption
    ;

  cfg = config.theonecfg.programs.luciole;

  toml = pkgs.formats.toml { };

  # Luciole reads config.toml as its base and writes GUI changes to a
  # separate settings.toml, so a read-only config file is fine.
  configFile = pkgs.runCommand "luciole-config.toml" { } ''
    cp ${toml.generate "luciole-config.toml" cfg.settings} $out
    ${lib.getExe pkgs.luciole} config validate $out
  '';

in
{

  options.theonecfg.programs.luciole = {
    enable = mkEnableOption "Luciole, the Noctalia project's file manager";

    settings = mkOption {
      inherit (toml) type;
      default = { };
      description = "Written to ~/.config/luciole/config.toml and validated at build time.";
    };
  };

  config = mkIf cfg.enable {

    home.packages = [ pkgs.luciole ];

    xdg.configFile."luciole/config.toml" = mkIf (cfg.settings != { }) {
      source = configFile;
    };

    # Open folders in Luciole. xdg-mime edits ~/.config/mimeapps.list in
    # place, so the file stays writable and the entries apps add themselves
    # are kept; xdg.mimeApps would take over the whole file instead.
    home.activation.lucioleDefaultFileManager = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${pkgs.xdg-utils}/bin/xdg-mime default dev.noctalia.luciole.desktop inode/directory
    '';

    # Answer "show in folder" requests (org.freedesktop.FileManager1) from
    # any app. The session bus reads ~/.local/share/dbus-1/services, but not
    # the home-manager profile where the package installs this file.
    xdg.dataFile."dbus-1/services/dev.noctalia.luciole.FileManager1.service".source =
      "${pkgs.luciole}/share/dbus-1/services/dev.noctalia.luciole.FileManager1.service";

    # Serve file-open and save dialogs for apps that ask the desktop portal;
    # the NixOS niri module routes them here. The portal finds the .portal
    # file in the profile, but the service file has to be linked as above.
    xdg.dataFile."dbus-1/services/org.freedesktop.impl.portal.desktop.luciole.service".source =
      "${pkgs.luciole}/share/dbus-1/services/org.freedesktop.impl.portal.desktop.luciole.service";

    # Noctalia's built-in template writes ~/.config/luciole/colors.toml from
    # its palette, and Luciole reloads that file live.
    programs.noctalia.settings.theme.templates.builtin_ids = mkIf config.programs.noctalia.enable [
      "luciole"
    ];

  };

}
