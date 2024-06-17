{
  fileSystems."/persist".neededForBoot = true;
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/spool"
      "/var/tmp"
      "/etc/NetworkManager/system-connections"
    ];
    files = [ "/etc/machine-id" ];
  };
}
