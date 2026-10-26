{
  fileSystems."/persist".neededForBoot = true;

  # /var/lib/private holds state for DynamicUser=yes services (real data
  # lives at /var/lib/private/<svc>; /var/lib/<svc> is a managed symlink
  # systemd recreates on each activation). systemd refuses to use
  # /var/lib/private if it isn't mode 0700 — see exec-invoke.c
  # mkdir_safe_label call. Impermanence's createPersistentStorageDirs
  # creates /var/lib/private with default 0755 when bind-mount targets
  # under it are needed; that loose mode then gets carried over to the
  # live /var/lib/private and breaks every DynamicUser service.
  #
  # Workaround per nix-community/impermanence#254: an activation script
  # ordered BEFORE createPersistentStorageDirs ensures /persist's
  # underlying directory is 0700 from the start. A plain tmpfiles rule
  # is insufficient — impermanence re-runs on activation and overwrites.
  system.activationScripts."var-lib-private-permissions" = {
    deps = [ "specialfs" ];
    text = ''
      mkdir -p /persist/var/lib/private
      chmod 0700 /persist/var/lib/private
    '';
  };
  system.activationScripts.createPersistentStorageDirs.deps = [
    "var-lib-private-permissions"
  ];

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
      #
      # DynamicUser=yes services keep their real state at
      # /var/lib/private/<svc>; the /var/lib/<svc> symlink is recreated
      # by systemd each activation, so persisting the symlink path
      # captures nothing. Persist /var/lib/private/<svc> for these.
      "/var/lib/private/AdGuardHome" # DynamicUser
      "/var/lib/caddy"
      "/var/lib/kanidm"
      # oauth2-proxy is stateless — no StateDirectory in the upstream module.
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
