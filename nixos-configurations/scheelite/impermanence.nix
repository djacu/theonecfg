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

      # Service state that must survive root rollback. Service modules
      # don't declare these themselves (would couple them to a specific
      # impermanence layout); the host owns the persistence policy.
      "/var/lib/AdGuardHome"
      "/var/lib/caddy"
      "/var/lib/private/kanidm"
      "/var/lib/oauth2_proxy"
      "/var/lib/grafana"
      "/var/lib/loki"
      "/var/lib/prometheus2"
      "/var/lib/nixos-containers"
      "/var/lib/sops-nix"
      "/var/lib/seerr"
      "/var/lib/recyclarr"
      "/var/lib/pinchflat"
    ];
    files = [
      "/etc/machine-id"

      # prevent fingerprint from changing
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };
}
