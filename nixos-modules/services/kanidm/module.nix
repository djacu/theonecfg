{
  config,
  lib,
  pkgs,
  theonecfg,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    mkMerge
    ;

  inherit (lib.options)
    mkEnableOption
    mkOption
    ;

  inherit (lib.types)
    str
    ;

  cfg = config.theonecfg.services.kanidm;

  # Display name and email default to the values in theonecfg.knownUsers
  # so a person's identity lives in one place. Both options remain
  # overridable per-host if the kanidm record needs to differ.
  personData = theonecfg.knownUsers.${cfg.person};

in
{
  options.theonecfg.services.kanidm = {
    enable = mkEnableOption "Kanidm IdP";
    domain = mkOption {
      type = str;
      default = "id.${config.theonecfg.networking.lanDomain}";
      description = "Public-facing domain for the Kanidm UI and OAuth2 endpoints.";
    };
    bindAddress = mkOption {
      type = str;
      default = "127.0.0.1:8443";
      description = "Internal bind address; Caddy reverse-proxies to this.";
    };
    ldapBindAddress = mkOption {
      type = str;
      default = "127.0.0.1:6636";
      description = "LDAP TLS bind address (for services that need LDAP rather than OIDC).";
    };
    person = mkOption {
      type = str;
      description = ''
        Primary person username provisioned in Kanidm. Must be a key in
        theonecfg.knownUsers; their `name` and `email` fields populate
        the Kanidm person record.
      '';
    };
    personDisplayName = mkOption {
      type = str;
      default = personData.name;
      defaultText = lib.literalExpression "theonecfg.knownUsers.\${cfg.person}.name";
      description = "Display name for the kanidm person record. Defaults to the user's name in theonecfg.knownUsers.";
    };
    personMail = mkOption {
      type = str;
      default = personData.email;
      defaultText = lib.literalExpression "theonecfg.knownUsers.\${cfg.person}.email";
      description = "Email for the kanidm person record. Defaults to the user's email in theonecfg.knownUsers.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.kanidm = {
        # Upstream removed the unversioned `pkgs.kanidm` alias; the
        # module now requires an explicit version. The provision feature
        # we use needs the `WithSecretProvisioning` variant.
        package = pkgs.kanidmWithSecretProvisioning_1_9;
        server.enable = true;
        server.settings = {
          domain = cfg.domain;
          origin = "https://${cfg.domain}";
          bindaddress = cfg.bindAddress;
          ldapbindaddress = cfg.ldapBindAddress;
          tls_chain = "/var/lib/kanidm/cert.pem";
          tls_key = "/var/lib/kanidm/key.pem";
        };
        client.enable = true;
        client.settings.uri = "https://${cfg.domain}";
        provision = {
          enable = true;
          adminPasswordFile = config.sops.secrets."kanidm/admin".path;
          idmAdminPasswordFile = config.sops.secrets."kanidm/idm-admin".path;
          groups."homelab-users".members = [ cfg.person ];
          persons.${cfg.person} = {
            displayName = cfg.personDisplayName;
            mailAddresses = [ cfg.personMail ];
            groups = [ "homelab-users" ];
          };
        };
      };

      sops.secrets = {
        "kanidm/admin" = { };
        "kanidm/idm-admin" = { };
      };

      # Generate a self-signed TLS cert/key for Kanidm if they don't exist.
      # Kanidm requires its own TLS even on localhost; Caddy reverse-proxies to
      # this with tls_insecure_skip_verify since the cert is host-internal.
      systemd.services.kanidm-tls-bootstrap = {
        description = "Generate self-signed Kanidm TLS material if missing";
        wantedBy = [ "kanidm.service" ];
        before = [ "kanidm.service" ];
        path = [ pkgs.openssl ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StateDirectory = "kanidm";
        };
        script = ''
          if [ ! -f /var/lib/kanidm/cert.pem ]; then
            openssl req -x509 -newkey rsa:2048 -nodes \
              -keyout /var/lib/kanidm/key.pem \
              -out /var/lib/kanidm/cert.pem \
              -days 3650 \
              -subj "/CN=${cfg.domain}" \
              -addext "subjectAltName=DNS:${cfg.domain}"
            chown kanidm:kanidm /var/lib/kanidm/cert.pem /var/lib/kanidm/key.pem
            chmod 600 /var/lib/kanidm/key.pem
            chmod 644 /var/lib/kanidm/cert.pem
          fi
        '';
      };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        reverse_proxy https://${cfg.bindAddress} {
          transport http {
            tls_insecure_skip_verify
          }
        }
      '';
    })
  ]);
}
