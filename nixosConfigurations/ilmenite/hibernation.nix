# Suspend-then-hibernate for ilmenite. Design and verified facts:
# docs/plans/completed/ilmenite-hibernation.md.
{ pkgs, ... }:
{
  # The ZFS module puts `nohibernate` on the kernel command line unless this
  # is set, and asserts that the root pool is not force-imported: a forced
  # import under a kernel that is about to resume corrupts the pool.
  boot.zfs.unsafeAllowHibernation = true;

  # First host in the fleet with `false`. The hostid is a fixed hash of the
  # hostname and is present in the initrd, so a crash on this machine imports
  # without -f. Recovery from a refused import is zfs_force=1 typed into the
  # systemd-boot editor, which stays enabled.
  boot.zfs.forceImportRoot = false;

  # Upstream orders nothing between the pool import and the resume unit, so
  # on a resume boot the initrd could import, roll back, and mount the pool
  # before the kernel swaps in the hibernated session. The resume unit binds
  # to the swap mapper, so this also waits for the swap unlock. The second
  # entry waits for the pool container explicitly instead of through the
  # import script's 60-second device retry loop.
  boot.initrd.systemd.services.zfs-import-zroot.after = [
    "systemd-hibernate-resume.service"
    "systemd-cryptsetup@cryptzroot.service"
  ];

  # What "sleep" means to systemd. On battery: s2idle, then a wake at 3 h
  # that hibernates. SuspendEstimationSec matches the delay so systemd adds
  # no extra estimation wake before it knows a drain rate; once it has one,
  # a low battery can bring the check forward. On AC the deadline is
  # re-armed at every wake, so a docked laptop wakes briefly every 3 h,
  # checks, and suspends again; unplug it and it hibernates at the next
  # check. The firmware battery alarm is disabled further down.
  systemd.sleep.settings.Sleep = {
    HibernateDelaySec = "3h";
    HibernateOnACPower = false;
    SuspendEstimationSec = "3h";
  };

  # Lid handling when no desktop session is running (SDDM screen). Plasma
  # takes the lid over while a session runs. On AC the lid does nothing.
  services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";
  services.logind.settings.Login.HandleLidSwitchExternalPower = "ignore";

  # Plasma's lid, idle and power-profile policy. SleepMode 3 =
  # suspend-then-hibernate; LidAction/AutoSuspendAction 0 = do nothing, 2 =
  # hibernate at once. On AC the laptop never sleeps on its own and runs the
  # power-profiles-daemon performance profile; on battery it keeps Plasma's
  # defaults and the balanced profile. LowBattery sets balanced too: an
  # unplug at or below 10% loads it straight from AC, and a profile with no
  # PowerProfile leaves the previous one active. Powerdevil acts on lid
  # changes only, so an unplug with the lid already closed stays awake until
  # the Battery profile's idle timeout (10 min default) sleeps it; logind
  # rechecks a closed lid by itself. /etc/xdg is in XDG_CONFIG_DIRS (after
  # ~/.config/kdedefaults on Plasma, which ships no powerdevilrc), so this
  # is a system default that the user's own powerdevilrc overrides.
  environment.etc."xdg/powerdevilrc".text = ''
    [AC][SuspendAndShutdown]
    AutoSuspendAction=0
    LidAction=0
    SleepMode=3

    [AC][Performance]
    PowerProfile=performance

    [Battery][SuspendAndShutdown]
    SleepMode=3

    [Battery][Performance]
    PowerProfile=balanced

    [LowBattery][SuspendAndShutdown]
    LidAction=2
    SleepMode=3

    [LowBattery][Performance]
    PowerProfile=balanced
  '';

  # Intel Bluetooth over PCIe (btintel_pcie) intermittently refuses to enter
  # D3 from its sleep callbacks on this controller; the kernel then rolls a
  # hibernate back after the image is written and the laptop stays on
  # (verification test 2a). The upstream fix was merged to bluetooth-next on
  # 2026-09-29 and is not in 6.18.49. Until the pin carries it, unload the
  # module before every sleep and reload it after. The unit follows
  # sleep.target's documented pattern: started before the target, stopped
  # when the target is torn down after resume, so ExecStop is the reload.
  systemd.services.btintel-pcie-sleep = {
    description = "Unload btintel_pcie around sleep";
    wantedBy = [ "sleep.target" ];
    before = [ "sleep.target" ];
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.kmod}/bin/modprobe -r btintel_pcie";
      ExecStop = "${pkgs.kmod}/bin/modprobe btintel_pcie";
    };
  };

  # The hibernation image may not exceed about half of RAM, and the ZFS ARC
  # counts towards it: the kernel's one reclaim pass cannot shed tens of
  # gigabytes of ARC, and a 55 GB ARC aborted hibernation with "Image
  # allocation is 5925659 pages short" (verification test 2d). Cap the ARC at
  # a quarter of RAM so the image always fits with room for applications.
  # The initrd copies this file, so the cap applies from the first import.
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=17179869184
  '';

  # systemd's suspend-then-hibernate takes the firmware battery-alarm path
  # when the battery exposes an alarm, and on that path it decides whether a
  # wake was the timer by reading the SMBIOS wake-up type, which this
  # firmware does not update on a resume from s2idle: the timed wake was
  # treated as manual and the machine stayed on (verification test 3).
  # With the trip point disabled the alarm reads 0 and systemd uses its own
  # timer loop, which also handles the low-battery estimate.
  #
  # The second rule works around this firmware notifying the ACPI AC device
  # before the adapter state has changed. drivers/acpi/ac.c reads the state
  # once in the notify handler and never again (its grace delay is keyed on a
  # DMI table of two other machines), so on an unplug the change uevent still
  # carried ONLINE=1. upower reads sysfs a few milliseconds later and
  # sometimes loses the race, then reports AC until the next plug event, and
  # powerdevil keeps the AC profile and performance on battery. So a second
  # after every adapter event, re-read the state and re-emit the event if the
  # original carried a stale value. The re-emitted event carries the fresh
  # value, so it does not re-emit again. Do not re-emit from the battery's
  # change event instead: that looped once a second, with a battery event
  # following each re-emitted adapter event; the cause was not identified.
  # Observed with udevadm monitor 2026-10-25.
  #
  # Keep the rule through kernel and firmware bumps; it is a no-op once the
  # kernel's own event carries the settled value. To check whether that has
  # happened, run `udevadm monitor -u -p -s power_supply` through a few
  # unplugs. The rule can go once the first ACAD event of every unplug
  # carries POWER_SUPPLY_ONLINE=0.
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", KERNEL=="BAT1", ATTR{alarm}="0"
    SUBSYSTEM=="power_supply", KERNEL=="ACAD", ACTION=="change", RUN+="${pkgs.writeShellScript "acad-reread" ''
      sleep 1
      read -r online < /sys/class/power_supply/ACAD/online
      [ "$online" = "$POWER_SUPPLY_ONLINE" ] || echo change > /sys/class/power_supply/ACAD/uevent
    ''}"
  '';
}
