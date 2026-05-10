{ config, lib, pkgs, ... }:
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) bool int str;

  cfg = config.theonecfg.services.stasharr;
  pgInstance = config.theonecfg.services.postgres.instances.stasharr;
in
{
  options.theonecfg.services.stasharr = {
    enable = mkEnableOption "Stasharr Portal";
    domain = mkOption {
      type = str;
      default = "stasharr.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 8084;
    };
    host = mkOption {
      type = str;
      default = "127.0.0.1";
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/stasharr";
    };
    dbPort = mkOption {
      type = int;
      default = 5441;
      description = "Host port that forwards into the Stasharr postgres container.";
    };
    cookieSecure = mkOption {
      type = bool;
      default = true;
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      users.users.stasharr = {
        isSystemUser = true;
        group = "stasharr";
        home = cfg.dataDir;
      };
      users.groups.stasharr = { };

      theonecfg.services.postgres.instances.stasharr = {
        version = "16";
        port = cfg.dbPort;
        databases = [ "stasharr" ];
        owner = "stasharr";
      };

      sops.secrets."stasharr/postgres-password".owner = "stasharr";
      sops.templates."stasharr.env" = {
        content = ''
          POSTGRES_PASSWORD=${config.sops.placeholder."stasharr/postgres-password"}
        '';
        owner = "stasharr";
      };

      # `z` (not `d`) so ownership is adjusted on existing dirs — the
      # dataDir is a ZFS dataset created out-of-band by `zfs create`,
      # which leaves it root-owned. Same pattern as the stash module.
      systemd.tmpfiles.rules = [
        "z ${cfg.dataDir} 0700 stasharr stasharr - -"
      ];

      systemd.services.stasharr = {
        description = "Stasharr Portal";
        after = [ "network.target" "container@postgres-stasharr.service" ];
        requires = [ "container@postgres-stasharr.service" ];
        wantedBy = [ "multi-user.target" ];
        path = with pkgs; [ openssl coreutils nodejs_22 ];
        environment = {
          NODE_ENV = "production";
          HOST = cfg.host;
          PORT = toString cfg.port;
          POSTGRES_DB = "stasharr";
          POSTGRES_USER = "stasharr";
          DATABASE_HOST = pgInstance.host;
          DATABASE_MIGRATION_MAX_ATTEMPTS = "30";
          DATABASE_MIGRATION_RETRY_DELAY_SECONDS = "2";
          SESSION_COOKIE_SECURE = if cfg.cookieSecure then "true" else "false";
          APP_DATA_DIR = cfg.dataDir;
          SESSION_SECRET_FILE = "${cfg.dataDir}/session-secret";
          STASHARR_VERSION = pkgs.stasharr-portal.version;
          # Prisma's "Precompiled engine files are not available for
          # nixos" — it can't ship a binary that works on nixos's
          # libc, so it expects this env var to point at a locally-
          # built schema-engine. nixpkgs' prisma-engines_7 builds
          # exactly that.
          PRISMA_SCHEMA_ENGINE_BINARY = "${pkgs.prisma-engines_7}/bin/schema-engine";
        };
        serviceConfig = {
          User = "stasharr";
          Group = "stasharr";
          WorkingDirectory = "${pkgs.stasharr-portal}/share/stasharr-portal";
          EnvironmentFile = config.sops.templates."stasharr.env".path;
          ExecStart = "${pkgs.stasharr-portal}/bin/stasharr-portal";
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
