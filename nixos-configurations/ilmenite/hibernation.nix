# Suspend-then-hibernate for ilmenite. Design and verified facts:
# docs/plans/active/ilmenite-hibernation.md.
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

  # What "sleep" means to systemd. On battery: s2idle, then one wake at 3 h
  # that hibernates; the firmware battery alarm hibernates earlier if the
  # battery exposes one. SuspendEstimationSec matches the delay so the only
  # timed wake is the one that hibernates. On AC the deadline is re-armed at
  # every wake, so a docked laptop wakes briefly every 3 h, checks, and
  # suspends again; unplug it and it hibernates at the next check.
  systemd.sleep.settings.Sleep = {
    HibernateDelaySec = "3h";
    HibernateOnACPower = false;
    SuspendEstimationSec = "3h";
  };

  # Lid handling when no desktop session is running (SDDM screen). Plasma
  # takes the lid over while a session runs.
  services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";

  # Plasma's lid policy. SleepMode 3 = suspend-then-hibernate; LidAction 2 =
  # hibernate at once. /etc/xdg is first in XDG_CONFIG_DIRS, so this is a
  # system default that the user's own powerdevilrc overrides.
  environment.etc."xdg/powerdevilrc".text = ''
    [AC][SuspendAndShutdown]
    SleepMode=3

    [Battery][SuspendAndShutdown]
    SleepMode=3

    [LowBattery][SuspendAndShutdown]
    LidAction=2
    SleepMode=3
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
}
