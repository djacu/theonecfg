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
    bool
    int
    str
    ;

  cfg = config.theonecfg.services.jellyfin;
  declarative = theonecfg.library.declarative pkgs;
  arrTypes = theonecfg.library.arrTypes;

  baseUrl = "http://127.0.0.1:${toString cfg.port}";

  sonarrCfg = config.theonecfg.services.sonarr;
  sonarrAnimeCfg = config.theonecfg.services.sonarr-anime;
  radarrCfg = config.theonecfg.services.radarr;
  pinchflatCfg = config.theonecfg.services.pinchflat;

  # Auto-derived libraries from enabled *arr / pinchflat modules. Library
  # paths follow whatever each *arr's rootFolders is configured to point at,
  # so the host's path policy (e.g. /tank0/media/...) doesn't need to be
  # repeated here.
  autoLibraries =
    lib.optionalAttrs sonarrCfg.enable {
      "TV Shows" = {
        paths = map (r: r.path) sonarrCfg.rootFolders;
        type = "tvshows";
      };
    }
    // lib.optionalAttrs sonarrAnimeCfg.enable {
      "Anime" = {
        paths = map (r: r.path) sonarrAnimeCfg.rootFolders;
        type = "tvshows";
      };
    }
    // lib.optionalAttrs radarrCfg.enable {
      "Movies" = {
        paths = map (r: r.path) radarrCfg.rootFolders;
        type = "movies";
      };
    }
    // lib.optionalAttrs pinchflatCfg.enable {
      "YouTube" = {
        paths = [ pinchflatCfg.mediaDir ];
        type = "homevideos";
      };
    };

  effectiveLibraries =
    if cfg.autoLibraries then autoLibraries // cfg.extraLibraries else cfg.extraLibraries;

in
{
  options.theonecfg.services.jellyfin = {
    enable = mkEnableOption "Jellyfin media server";
    domain = mkOption {
      type = str;
      default = "jellyfin.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 8096;
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/jellyfin";
    };
    cacheDir = mkOption {
      type = str;
      default = "/var/cache/jellyfin";
    };
    serverName = mkOption {
      type = str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Friendly name shown to Jellyfin clients.";
    };
    adminUser = mkOption {
      type = str;
      description = ''
        Admin username created during the wizard bootstrap. Must be a
        key in theonecfg.knownUsers (jellyseerr looks up its email
        from there).
      '';
    };
    autoLibraries = mkOption {
      type = bool;
      default = true;
      description = ''
        Auto-derive libraries from enabled *arr / pinchflat modules.
        Each *arr contributes its configured rootFolders; pinchflat
        contributes its mediaDir. Disabled modules are skipped.
      '';
    };
    extraLibraries = mkOption {
      type = attrsOf arrTypes.jellyfinLibraryType;
      default = { };
      description = "Additional libraries beyond the auto-derived ones.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.jellyfin = {
        enable = true;
        dataDir = cfg.dataDir;
        cacheDir = cfg.cacheDir;
      };

      # Upstream creates dataDir/configDir/logDir/cacheDir via tmpfiles and
      # sets RequiresMountsFor on configDir/logDir/cacheDir (but not dataDir).
      # We add dataDir + each library's path.
      systemd.services.jellyfin.unitConfig.RequiresMountsFor = [
        cfg.dataDir
      ]
      ++ lib.concatMap (library: library.paths) (lib.attrValues effectiveLibraries);

      sops.secrets."jellyfin/admin-password".owner = "jellyfin";
    }

    # Run-once admin user bootstrap via /Startup/* endpoints. Idempotent.
    (declarative.mkJellyfinBootstrap {
      inherit baseUrl;
      serverName = cfg.serverName;
      adminUser = cfg.adminUser;
      adminPasswordFile = config.sops.secrets."jellyfin/admin-password".path;
    })

    # Library reconciliation via /Library/VirtualFolders.
    (mkIf (effectiveLibraries != { }) (
      declarative.mkJellyfinLibrarySync {
        inherit baseUrl;
        adminUser = cfg.adminUser;
        adminPasswordFile = config.sops.secrets."jellyfin/admin-password".path;
        libraries = effectiveLibraries;
      }
    ))

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
