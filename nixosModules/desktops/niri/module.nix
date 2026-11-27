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
    ;

  cfg = config.theonecfg.desktops.niri;

in
{

  options.theonecfg.desktops.niri.enable = mkEnableOption "theonecfg niri setup";

  config = mkIf cfg.enable {

    programs.niri.enable = true;
    # The default registers Nautilus on the session bus as the file-open
    # dialog back end, which also makes it answer "show in folder" requests
    # (org.freedesktop.FileManager1). Luciole is the file manager here; the
    # file-open dialogs fall back to the GTK portal's chooser.
    programs.niri.useNautilus = false;

    # home-manager owns the Noctalia user service, so systemd.enable stays
    # off here.
    programs.noctalia = {
      enable = true;
      recommendedServices.enable = true;
    };

    services.displayManager.noctalia-greeter = {
      enable = true;
      cursorTheme.package = pkgs.adwaita-icon-theme;
    };

    # "login" is the service behind the greeter (greetd substacks it), the
    # text console and Noctalia's lock screen. The lock screen drives the
    # fingerprint reader itself and cannot share it with pam_fprintd. At the
    # greeter the login is by password, and with pam_fprintd first a typed
    # password waited out a 30 s fingerprint timeout before it was checked.
    # sudo and polkit have their own services and keep fingerprint.
    security.pam.services.login.fprintAuth = false;

    # Plasma's module used to turn these on.
    services.libinput.enable = true;
    services.udisks2.enable = true;
    services.fwupd.enable = true;
    programs.dconf.enable = true;
    programs.gdk-pixbuf.modulePackages = [ pkgs.librsvg ];

    # Comes on with gnome-keyring, which the niri module enables. A second
    # SSH agent is not wanted.
    services.gnome.gcr-ssh-agent.enable = false;

    # Trash, mounting and network locations for GIO file managers such as
    # Luciole and Nautilus. Plasma used KIO instead and never needed it.
    services.gvfs.enable = true;

  };

}
