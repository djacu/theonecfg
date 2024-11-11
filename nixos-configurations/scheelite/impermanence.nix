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
    ];
    files = [ "/etc/machine-id" ];
  };
}
