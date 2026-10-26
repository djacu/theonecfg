{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkAfter
    mkIf
    mkMerge
    ;

  inherit (lib.options)
    mkEnableOption
    mkOption
    ;

  inherit (lib.types)
    int
    str
    ;

  cfg = config.theonecfg.services.adguard;

  # Bcrypt the sops-managed plaintext into AdGuardHome.yaml's
  # users[0].password field on every restart. AdGuard requires a bcrypt
  # hash (no plaintext support); we keep the plaintext in sops and hash
  # at runtime so the hash never lands in the world-readable Nix store.
  # Same shape as qbtPasswordHashScript in library/declarative-arr.nix
  # but using bcrypt + yq-go for AdGuard's YAML format.
  passwordHashApp = pkgs.writeShellApplication {
    name = "adguardhome-password-hash";
    runtimeInputs = [
      pkgs.mkpasswd
      pkgs.yq-go
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail

      configFile=/var/lib/private/AdGuardHome/AdGuardHome.yaml
      plaintextFile=${config.sops.secrets."adguard/admin-password".path}

      if [ ! -r "$plaintextFile" ]; then
        echo "AdGuard plaintext password file not readable: $plaintextFile" >&2
        exit 1
      fi

      if [ ! -f "$configFile" ]; then
        echo "AdGuardHome.yaml not yet present: $configFile; nothing to do." >&2
        exit 0
      fi

      plaintext=$(tr -d '\n' < "$plaintextFile")
      hash=$(mkpasswd -m bcrypt -s <<< "$plaintext")

      # yq -i replaces the file via atomic-rename; since we run as root
      # via the `+` ExecStartPre prefix, the new file ends up root:root.
      # Capture the original DynamicUser ownership/mode and restore it
      # after, so adguardhome's runtime can still read/write the file.
      orig_uid=$(stat -c '%u' "$configFile")
      orig_gid=$(stat -c '%g' "$configFile")
      orig_mode=$(stat -c '%a' "$configFile")

      NEW_HASH=$hash yq -i '.users[0].password = strenv(NEW_HASH)' "$configFile"

      chown "$orig_uid:$orig_gid" "$configFile"
      chmod "$orig_mode" "$configFile"
    '';
  };

in
{
  options.theonecfg.services.adguard = {
    enable = mkEnableOption "AdGuard Home (LAN DNS + ad blocking)";
    domain = mkOption {
      type = str;
      default = "adguard.${cfg.lanDomain}";
      description = "Caddy vhost serving AdGuard's web UI over HTTPS.";
    };
    port = mkOption {
      type = int;
      default = 3000;
      description = "AdGuard Home web UI port; bound to loopback (Caddy proxies from there).";
    };
    lanIp = mkOption {
      type = str;
      description = ''
        IP address advertised as the wildcard target for *.''${lanDomain}.
        The host that runs AdGuard supplies this — typically a let-binding
        also feeding networking.interfaces.<iface>.ipv4.addresses, so the
        IP is set in one place per host.
      '';
      example = "10.0.10.111";
    };
    lanDomain = mkOption {
      type = str;
      default = config.theonecfg.networking.lanDomain;
      description = "Wildcard domain whose subdomains resolve to the host.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # DNS listeners on 53 need explicit firewall rules. The web UI now
      # binds to loopback only and is reachable exclusively via Caddy on
      # 443 — no inbound firewall hole for the UI port.
      networking.firewall.allowedTCPPorts = [ 53 ];
      networking.firewall.allowedUDPPorts = [ 53 ];

      services.adguardhome = {
        enable = true;
        mutableSettings = false;
        host = "127.0.0.1";
        port = cfg.port;
        openFirewall = false;
        settings = {
          users = [
            {
              name = "admin";
              # Placeholder. The bcrypt hash gets sed-injected into the
              # rendered AdGuardHome.yaml at runtime by the
              # `adguardhome-password-hash` ExecStartPre below. Keeping
              # the placeholder here means the hash never lands in the
              # world-readable Nix store.
              password = "ADGUARD_PASSWORD_PLACEHOLDER";
            }
          ];
          dns = {
            bind_hosts = [ "0.0.0.0" ];
            port = 53;
            # Bootstrap servers used to resolve the upstream DoH hostnames
            # themselves before AdGuard is fully online. Plain UDP/53.
            bootstrap_dns = [
              "1.1.1.1"
              "9.9.9.9"
            ];
            upstream_dns = [
              "https://1.1.1.1/dns-query"
              "https://9.9.9.9/dns-query"
            ];
          };
          filtering = {
            filtering_enabled = true;
            rewrites_enabled = true;
            # Rewrites live under filtering, not dns (current AdGuard
            # schema_version 33). Putting them under dns silently fails —
            # AdGuard ignores them and writes the default empty list at
            # filtering.rewrites.
            rewrites = [
              {
                domain = "*.${cfg.lanDomain}";
                answer = cfg.lanIp;
                enabled = true;
              }
              {
                domain = cfg.lanDomain;
                answer = cfg.lanIp;
                enabled = true;
              }
            ];
          };
        };
      };

      # Bcrypt the admin password into the live AdGuardHome.yaml after
      # upstream's ExecStartPre installs the placeholder-bearing config.
      # `+` prefix runs the helper as root regardless of upstream's
      # User= (DynamicUser); root is needed to read the sops-protected
      # plaintext and to touch the DynamicUser-owned config file. The
      # helper itself restores the original ownership/mode after the
      # in-place yq edit.
      systemd.services.adguardhome.serviceConfig.ExecStartPre = mkAfter [
        "+${passwordHashApp}/bin/adguardhome-password-hash"
      ];

      sops.secrets."adguard/admin-password" = { };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      # AdGuard has its own admin login, so don't stack `forward_auth_kanidm`
      # on top — same pattern as Jellyfin/Paperless.
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
