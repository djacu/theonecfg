{
  fileSystems."/persist".neededForBoot = true;
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/lastlog"
      "/var/lib/upower"
      "/var/lib/NetworkManager"
      "/var/lib/bluetooth"
      "/var/lib/fwupd"
      "/var/lib/fprint"
      "/var/lib/private"
      "/var/lib/AccountsService"
      "/var/lib/sddm"
      "/var/lib/power-profiles-daemon"
      "/var/lib/udisks2"
      "/var/lib/cups/ppd"
      "/var/lib/cups/ssl"
      "/var/spool"
      "/var/tmp"
      "/etc/NetworkManager/system-connections"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
      "/var/lib/cups/subscriptions.conf"
      "/var/lib/cups/printers.conf"
      "/var/lib/cups/classes.conf"
    ];
  };
}
