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
    attrsOf
    int
    str
    submodule
    unspecified
    ;

  cfg = config.theonecfg.services.qbittorrent;
  declarative = theonecfg.library.declarative pkgs;

  # Auto-derive download categories from enabled *arr modules. Each *arr
  # gets a save path of ${downloadsDir}/<name>.
  enabledArrs = lib.filterAttrs (_: c: c.enable or false) {
    sonarr = config.theonecfg.services.sonarr;
    sonarr-anime = config.theonecfg.services.sonarr-anime;
    radarr = config.theonecfg.services.radarr;
    whisparr = config.theonecfg.services.whisparr;
  };

  autoCategories = lib.mapAttrs (name: _: "${cfg.downloadsDir}/${name}") enabledArrs;

  effectiveCategories =
    if cfg.autoCategories then autoCategories // cfg.extraCategories else cfg.extraCategories;

  configFilePath = "${cfg.profileDir}/qBittorrent/config/qBittorrent.conf";

  passwordHashApp = declarative.qbtPasswordHashScript {
    plaintextFile = config.sops.secrets."qbittorrent/password".path;
    configFile = configFilePath;
  };

  preferencesType = submodule {
    freeformType = attrsOf unspecified;
  };

in
{
  options.theonecfg.services.qbittorrent = {
    enable = mkEnableOption "qBittorrent (BitTorrent client)";
    domain = mkOption {
      type = str;
      default = "qbittorrent.${config.theonecfg.networking.lanDomain}";
    };
    webUiPort = mkOption {
      type = int;
      default = 8080;
      description = "qBittorrent WebUI port. Bound to 127.0.0.1; Caddy proxies from there.";
    };
    profileDir = mkOption {
      type = str;
      default = "/var/lib/qbittorrent";
      description = "Where qBittorrent stores its profile (BT_backup, settings, etc).";
    };
    downloadsDir = mkOption {
      type = str;
      default = "/var/lib/qbittorrent/downloads";
      description = "Where qBittorrent saves completed downloads (handed off to *arr stack).";
    };
    autoCategories = mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Auto-derive a category per enabled *arr module — each gets a
        save path of ''${downloadsDir}/<arr-name> (e.g. radarr →
        ''${downloadsDir}/radarr).
      '';
    };
    extraCategories = mkOption {
      type = attrsOf str;
      default = { };
      description = "Additional categories beyond the auto-derived ones.";
      example = lib.literalExpression ''
        {
          manual = "''${cfg.downloadsDir}/manual";
        }
      '';
    };
    preferences = mkOption {
      type = preferencesType;
      default = { };
      description = ''
        Additional preferences pushed via /api/v2/app/setPreferences.
        These are merged on top of the defaults this module sets (save paths,
        listen port, WebUI bindings).
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.qbittorrent = {
        enable = true;
        webuiPort = cfg.webUiPort;
        profileDir = cfg.profileDir;
        # serverConfig generates qBittorrent.conf at build time; upstream
        # installs it via ExecStartPre on every restart. The PBKDF2
        # password line gets sed-injected by our additional ExecStartPre
        # below — leaving it out of serverConfig avoids putting the hash
        # in the world-readable Nix store.
        serverConfig = {
          LegalNotice.Accepted = true;
          Preferences = {
            WebUI = {
              Address = "127.0.0.1";
              HostHeaderValidation = false;
              # B-lite localhost auth bypass — see scheelite-homelab-services.md.
              AuthSubnetWhitelistEnabled = true;
              AuthSubnetWhitelist = "127.0.0.1/32";
            };
            Downloads = {
              SavePath = cfg.downloadsDir;
              # qBittorrent uses backslash-prefixed nested keys in the INI
              # format; the upstream NixOS module's `gendeepINI` handles this.
            };
          };
        };
      };

      # Inject the PBKDF2 password hash AFTER upstream's ExecStartPre installs
      # the config file from /nix/store.
      systemd.services.qbittorrent.serviceConfig.ExecStartPre = lib.mkAfter [
        "${passwordHashApp}/bin/qbt-password-hash"
      ];

      sops.secrets."qbittorrent/password".owner = "qbittorrent";

      # qbittorrent isn't in NixOS's `ids.nix` static UID registry, so
      # config.ids.uids.qbittorrent doesn't exist. Reference the user/group
      # by name instead — systemd-tmpfiles accepts both, and names resolve
      # to whatever UID upstream NixOS or the host config assigned.
      systemd.tmpfiles.rules = [
        "d ${cfg.profileDir} 0750 ${config.services.qbittorrent.user} ${config.services.qbittorrent.group} - -"
        "d ${cfg.downloadsDir} 0775 ${config.services.qbittorrent.user} ${config.services.qbittorrent.group} - -"
      ]
      # One subdirectory per category for *arr handoff.
      ++ lib.mapAttrsToList (
        _: path:
        "d ${path} 0775 ${config.services.qbittorrent.user} ${config.services.qbittorrent.group} - -"
      ) effectiveCategories;

      systemd.services.qbittorrent.unitConfig.RequiresMountsFor = [
        cfg.profileDir
        cfg.downloadsDir
      ];
    }

    # Push runtime preferences + categories via REST API after qBittorrent is up.
    (mkIf (cfg.preferences != { } || effectiveCategories != { }) (
      declarative.mkQbtPushService {
        baseUrl = "http://127.0.0.1:${toString cfg.webUiPort}";
        preferences = cfg.preferences;
        categories = effectiveCategories;
      }
    ))

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.webUiPort}
      '';
    })
  ]);
}
