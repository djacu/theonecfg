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

  cfg = config.theonecfg.programs.noctalia;

  # Noctalia runs an idle command once per idle period, so wait here until
  # the laptop is on battery. systemd-ac-power exits 0 on AC.
  batterySleep = pkgs.writeShellScript "noctalia-battery-sleep" ''
    while ${pkgs.systemd}/bin/systemd-ac-power; do ${pkgs.coreutils}/bin/sleep 30; done
    ${pkgs.systemd}/bin/systemctl suspend-then-hibernate
  '';

in
{

  options.theonecfg.programs.noctalia.enable = mkEnableOption "noctalia config";

  config = mkIf cfg.enable {

    programs.noctalia = {
      enable = true;
      systemd.enable = true;

      settings = {

        # Off by default. Without an agent in the session, pkexec and other
        # polkit prompts have nothing to ask through and fail.
        shell.polkit_agent = true;

        # Noctalia runs as a systemd user service, and apps started from its
        # launcher land in that service's cgroup. Every restart of Noctalia,
        # including each home-manager switch that changes its config, then
        # kills them all. Start them as their own transient units instead.
        shell.launch_apps_as_systemd_services = true;

        # Noctalia's own suspend is a plain one, which never hibernates.
        shell.session.power.suspend = "${pkgs.systemd}/bin/systemctl suspend-then-hibernate";

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
    # second shell with its idle behaviours armed.
    systemd.user.services.noctalia.Unit.ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";

  };

}
