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
    mkOption
    ;

  inherit (lib.types)
    attrsOf
    listOf
    int
    str
    submodule
    ;

  inherit (lib.attrsets)
    mapAttrs'
    nameValuePair
    ;

  cfg = config.theonecfg.services.postgres;

  instanceModule =
    { name, ... }:
    {
      options = {
        version = mkOption {
          type = str;
          default = "16";
          description = "Major postgres version (e.g. \"16\"). Must match a pkgs.postgresql_<n> attribute.";
        };
        port = mkOption {
          type = int;
          description = "Host port forwarded to the container's postgres (5432 inside).";
        };
        databases = mkOption {
          type = listOf str;
          default = [ name ];
          description = "Databases to ensure exist.";
        };
        owner = mkOption {
          type = str;
          default = name;
          description = "Postgres role granted ownership of databases.";
        };
        extensions = mkOption {
          type = listOf str;
          default = [ ];
          description = ''
            Extension package attribute names. Each is looked up as
            `pkgs.postgresql_<version>.pkgs.<name>` and added to the container's
            postgres.extraPlugins.
          '';
        };
      };
    };

  subnetIndex = instance: instance.port - 5432;

  mkInstanceContainer =
    name: instance:
    let
      idx = subnetIndex instance;
    in
    {
      autoStart = true;
      privateNetwork = true;
      hostAddress = "10.233.${toString idx}.1";
      localAddress = "10.233.${toString idx}.2";
      forwardPorts = [
        {
          containerPort = 5432;
          hostPort = instance.port;
          protocol = "tcp";
        }
      ];
      bindMounts."/var/lib/postgresql/${instance.version}" = {
        hostPath = "${cfg.instancesDir}/${name}";
        isReadOnly = false;
      };
      config =
        { pkgs, ... }:
        {
          services.postgresql = {
            enable = true;
            package = pkgs."postgresql_${instance.version}";
            enableTCPIP = true;
            ensureDatabases = instance.databases;
            ensureUsers = [
              {
                name = instance.owner;
                ensureDBOwnership = true;
              }
            ];
            extraPlugins = map (ext: pkgs."postgresql_${instance.version}".pkgs.${ext}) instance.extensions;
            # ZFS already provides atomic block writes via copy-on-write, so
            # postgres's torn-page protection is redundant overhead. Disabling
            # it cuts WAL volume by ~50%. wal_init_zero/wal_recycle pre-zero
            # and recycle WAL segments on the assumption that overwriting
            # in-place is cheap — on COW that's never true (each "overwrite"
            # is a new block).
            settings = {
              full_page_writes = false;
              wal_init_zero = false;
              wal_recycle = false;
            };
            authentication = ''
              # Allow the host (and only the host) to connect without password
              # over the private veth network. The container is unreachable
              # from anywhere else (privateNetwork + no external routing).
              host all all 10.233.${toString idx}.0/24 trust
            '';
          };
          networking.firewall.allowedTCPPorts = [ 5432 ];
          system.stateVersion = "26.05";
        };
    };

in
{
  options.theonecfg.services.postgres = {
    enable = mkEnableOption "per-service postgres instances (one NixOS container per instance)";
    instancesDir = mkOption {
      type = str;
      default = "/var/lib/postgres-instances";
      description = ''
        Parent directory under which each instance's data lives at
        ''${instancesDir}/<instance-name>. The default matches the
        /var/lib pattern; on hosts where this path must survive a root
        rollback (impermanence), override to a persisted location such
        as /persist/postgres.
      '';
    };
    instances = mkOption {
      type = attrsOf (submodule instanceModule);
      default = { };
      description = "Map of service name -> postgres instance settings.";
    };
  };

  config = mkIf cfg.enable {
    containers = mapAttrs' (
      name: instance: nameValuePair "postgres-${name}" (mkInstanceContainer name instance)
    ) cfg.instances;

    systemd.tmpfiles.rules = [
      # Parent directory for all per-service postgres data dirs.
      "d ${cfg.instancesDir} 0755 root root - -"
    ]
    ++ lib.attrsets.mapAttrsToList (
      name: _:
      # postgres uid/gid is stable across NixOS hosts and containers
      # (defined in nixos/modules/misc/ids.nix as 71). Looking it up via
      # config.ids keeps the module robust if upstream ever renumbers.
      "d ${cfg.instancesDir}/${name} 0700 ${toString config.ids.uids.postgres} ${toString config.ids.gids.postgres} - -"
    ) cfg.instances;
  };
}
