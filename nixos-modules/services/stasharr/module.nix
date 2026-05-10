{ config, lib, pkgs, ... }:
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) bool enum int listOf nullOr str submodule;

  cfg = config.theonecfg.services.stasharr;
  pgInstance = config.theonecfg.services.postgres.instances.stasharr;

  bootstrapAdminType = submodule {
    options = {
      usernameFile = mkOption {
        type = str;
        description = "Path to a file containing the local-admin username.";
      };
      passwordFile = mkOption {
        type = str;
        description = "Path to a file containing the local-admin password.";
      };
    };
  };

  integrationType = submodule {
    options = {
      type = mkOption {
        type = enum [ "WHISPARR" "STASH" "STASHDB" "FANSDB" ];
      };
      baseUrl = mkOption {
        type = str;
        description = "URL Stasharr's server-side fetch will use to reach this integration.";
      };
      apiKeyFile = mkOption {
        type = str;
        description = "Path to a file containing the integration's API key.";
      };
    };
  };

  bootstrapApp = pkgs.writeShellApplication {
    name = "stasharr-bootstrap";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      base_url="http://${cfg.host}:${toString cfg.port}"
      cookie_jar="$(mktemp)"
      trap 'rm -f "$cookie_jar"' EXIT

      # Wait for the app to start serving.
      end=$((SECONDS + 120))
      until curl -sf "$base_url/api/auth/status" >/dev/null 2>&1; do
        if [ $SECONDS -ge $end ]; then
          echo "timeout waiting for stasharr at $base_url" >&2
          exit 1
        fi
        sleep 2
      done

      ${lib.optionalString (cfg.bootstrapAdmin != null) ''
        username="$(tr -d '\r\n' < "${cfg.bootstrapAdmin.usernameFile}")"
        password="$(tr -d '\r\n' < "${cfg.bootstrapAdmin.passwordFile}")"
        body=$(jq -nc --arg u "$username" --arg p "$password" \
          '{username:$u, password:$p}')

        # Bootstrap is a one-shot; 409 means already bootstrapped, in
        # which case we log in to get a session cookie for subsequent
        # integration upserts.
        code=$(curl -s -o /dev/null -w "%{http_code}" \
          -c "$cookie_jar" \
          -H "Content-Type: application/json" \
          -d "$body" \
          "$base_url/api/auth/bootstrap")
        case "$code" in
          200|201) echo "bootstrap: created admin (HTTP $code)" ;;
          409)
            echo "bootstrap: already done (HTTP $code), logging in"
            login_code=$(curl -s -o /dev/null -w "%{http_code}" \
              -c "$cookie_jar" \
              -H "Content-Type: application/json" \
              -d "$body" \
              "$base_url/api/auth/login")
            if [ "$login_code" -ge 400 ]; then
              echo "login failed (HTTP $login_code)" >&2
              exit 1
            fi
            ;;
          *) echo "bootstrap failed (HTTP $code)" >&2; exit 1 ;;
        esac
      ''}

      ${lib.optionalString (cfg.integrations != [ ]) ''
        push_integration() {
          local type="$1" base="$2" key="$3"
          local body
          body=$(jq -nc --arg b "$base" --arg k "$key" \
            '{enabled:true, baseUrl:$b, apiKey:$k}')
          local out
          out=$(mktemp); trap 'rm -f "$out"' RETURN
          local code
          code=$(curl -s -o "$out" -w "%{http_code}" \
            -b "$cookie_jar" \
            -X PUT \
            -H "Content-Type: application/json" \
            -d "$body" \
            "$base_url/api/integrations/$type")
          if [ "$code" -ge 400 ]; then
            echo "PUT /api/integrations/$type failed (HTTP $code):" >&2
            cat "$out" >&2
            exit 1
          fi
          echo "integrations/$type: HTTP $code"
        }

        ${lib.concatMapStringsSep "\n" (i: ''
          if [ ! -r "${i.apiKeyFile}" ]; then
            echo "stasharr integration apikey file not readable: ${i.apiKeyFile} (${i.type})" >&2
            exit 1
          fi
          int_key="$(tr -d '\r\n' < "${i.apiKeyFile}")"
          push_integration "${i.type}" "${i.baseUrl}" "$int_key"
        '') cfg.integrations}
      ''}
    '';
  };

  bootstrapServiceWanted = cfg.bootstrapAdmin != null || cfg.integrations != [ ];
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
    bootstrapAdmin = mkOption {
      type = nullOr bootstrapAdminType;
      default = null;
      description = ''
        If set, an idempotent systemd one-shot creates the local-admin
        account on first run via /api/auth/bootstrap and logs in
        on subsequent runs to maintain a session for integration upserts.
      '';
    };
    integrations = mkOption {
      type = listOf integrationType;
      default = [ ];
      description = ''
        Integrations to upsert via PUT /api/integrations/<type> on every
        restart. Requires bootstrapAdmin to be set (the integration
        endpoints are admin-gated).
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.integrations == [ ] || cfg.bootstrapAdmin != null;
          message = "theonecfg.services.stasharr.integrations requires bootstrapAdmin to be set (integration upserts are admin-authenticated).";
        }
      ];

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

    (mkIf bootstrapServiceWanted {
      systemd.services.stasharr-bootstrap = {
        description = "Bootstrap Stasharr admin and integrations";
        after = [ "stasharr.service" ];
        requires = [ "stasharr.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          # Runs as root so it can read each integration's apiKeyFile
          # regardless of the secret's individual owner; secrets are
          # mode 0400 owned by their respective service users.
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${bootstrapApp}/bin/stasharr-bootstrap";
        };
      };
    })

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
