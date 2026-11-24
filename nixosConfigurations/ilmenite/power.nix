# Power policy that a desktop's power daemon would otherwise provide.
# Design: docs/plans/active/ilmenite-niri-desktop.md.
{ config, pkgs, ... }:
{
  # Plasma's module used to turn these on.
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;

  # UPower's default at the critical level is hybrid sleep, which has never
  # been tested on this machine; hibernate has. The thresholds stay at
  # UPower's defaults. Not tested by draining the battery.
  services.upower.criticalPowerAction = "Hibernate";

  # niri's own power-button handling is turned off in its config because it
  # calls a plain suspend, which never hibernates. logind's default would be
  # power off.
  services.logind.settings.Login.HandlePowerKey = "suspend-then-hibernate";

  # Performance on AC, balanced on battery. PowerDevil used to do this.
  #
  # Wanted by graphical.target, not multi-user.target: the daemon orders
  # itself after multi-user.target, and a unit wanted by that target and
  # ordered after the daemon is dropped by systemd to break the loop.
  systemd.services.power-profile-ac = {
    description = "Set the power profile from the AC adapter state";
    wantedBy = [ "graphical.target" ];
    after = [ "power-profiles-daemon.service" ];
    requires = [ "power-profiles-daemon.service" ];
    path = [ pkgs.power-profiles-daemon ];
    serviceConfig.Type = "oneshot";
    script = ''
      set_profile() {
        read -r online < /sys/class/power_supply/ACAD/online
        if [ "$online" = 1 ]; then profile=performance; else profile=balanced; fi
        powerprofilesctl set "$profile"
      }
      set_profile
      # The adapter's first event can carry a stale state, and a start request
      # that arrives while this is running is merged, not queued.
      sleep 2
      set_profile
    '';
  };

  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", KERNEL=="ACAD", ACTION=="change", RUN+="${config.systemd.package}/bin/systemctl --no-block start power-profile-ac.service"
  '';

  # The charger can change while asleep.
  powerManagement.resumeCommands = ''
    ${config.systemd.package}/bin/systemctl --no-block start power-profile-ac.service
  '';
}
