{
  config,
  lib,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.desktops.plasma;

in
{

  options.theonecfg.desktops.plasma.enable = mkEnableOption "theonecfg plasma setup";

  config = mkIf cfg.enable {

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };
    services.desktopManager.plasma6.enable = true;

    # The lock screen runs the password check and the fingerprint check as
    # two separate helpers, each with its own PAM service: "kde" behind the
    # password field, "kde-fingerprint" behind the reader. NixOS puts
    # pam_unix after pam_fprintd in every service as a password fallback,
    # and in kde-fingerprint that fallback breaks the reader. When a scan
    # ends without a match (30 s with no finger, or a suspend that starts
    # mid-scan), pam_unix asks for a password through the fingerprint helper.
    # In the default setup the lock screen never answers prompts on that
    # helper, so it blocks there and the reader ignores every touch until the
    # screen is unlocked with the password. With pam_unix gone the failed
    # scan is reported back, and the lock screen starts a new one within a
    # second.
    #
    # Only kde-fingerprint changes; the password field, SDDM, sudo and polkit
    # use other services. The one thing lost: with Fingerprint chosen as the
    # lock screen's main method (off by default) there is no password prompt
    # after a scan times out.
    #
    # Diagnosed on obsidian (thethreecfg) 2026-11-18 with kscreenlocker
    # 6.8.3. Drop this once the nixpkgs plasma6 module stops putting pam_unix
    # in kde-fingerprint. Confirmed on ilmenite 2026-11-22.
    security.pam.services.kde-fingerprint = mkIf config.services.fprintd.enable {
      unixAuth = false;
    };

    # A scan that is still waiting when the system goes to sleep leaves
    # fprintd unusable until it restarts. The goodixmoc driver cannot carry a
    # scan across sleep, so fprintd cancels it. pam_fprintd then releases the
    # device while fprintd still has it marked suspended: the close is
    # refused, but fprintd drops the claim anyway and is left holding an open
    # device that nobody owns. After resume the lock screen asks again once a
    # second, each request is refused at once, and after five refusals (about
    # 4 s) it gives up on the reader for that lock. fprintd exits 30 s later
    # and would come back clean, but nothing asks any more.
    #
    # So stop fprintd on every resume. It is started on demand, so the next
    # scan request gets a fresh daemon. When it is not running, which is the
    # usual case, the stop does nothing.
    #
    # Diagnosed on obsidian (thethreecfg) 2026-11-18 with fprintd 1.94.5 and
    # libfprint 1.94.100. Drop this once fprintd survives a release that
    # arrives during suspend. Confirmed on ilmenite 2026-11-22.
    powerManagement.resumeCommands = mkIf config.services.fprintd.enable ''
      ${config.systemd.package}/bin/systemctl --no-block stop fprintd.service
    '';

  };

}
