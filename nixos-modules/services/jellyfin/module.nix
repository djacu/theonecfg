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
    listOf
    package
    str
    ;

  cfg = config.theonecfg.services.jellyfin;
  declarative = theonecfg.library.declarative pkgs;
  arrTypes = theonecfg.library.arrTypes;

  baseUrl = "http://127.0.0.1:${toString cfg.port}";

  sonarrCfg = config.theonecfg.services.sonarr;
  sonarrAnimeCfg = config.theonecfg.services.sonarr-anime;
  radarrCfg = config.theonecfg.services.radarr;
  whisparrCfg = config.theonecfg.services.whisparr;
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
    // lib.optionalAttrs whisparrCfg.enable {
      "Adult" = {
        paths = map (r: r.path) whisparrCfg.rootFolders;
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
    plugins = mkOption {
      type = listOf package;
      default = [ ];
      description = ''
        Jellyfin plugin packages to install. Each package must place its
        dll(s) at `$out/share/<pname>/`. The module symlinks each into
        `${cfg.dataDir}/plugins/<pname>_<version>/` at activation
        time so Jellyfin's plugin loader picks them up.

        Plugin configuration (per-plugin settings, secrets) is set in the
        Jellyfin UI after install; that state persists in the same config
        directory.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.jellyfin = {
        enable = true;
        dataDir = cfg.dataDir;
        cacheDir = cfg.cacheDir;
      };

      # Read access to /tank0/media/* (each rootFolder is sgid 2775 with
      # group=media). 0755 "other" would also let jellyfin read, but media
      # group membership keeps the option open for "save metadata into
      # media folders" features which need write.
      users.users.jellyfin.extraGroups = [ "media" ];

      # Upstream creates dataDir/configDir/logDir/cacheDir via tmpfiles and
      # sets RequiresMountsFor on configDir/logDir/cacheDir (but not dataDir).
      # We add dataDir + each library's path.
      systemd.services.jellyfin.unitConfig.RequiresMountsFor = [
        cfg.dataDir
      ]
      ++ lib.concatMap (library: library.paths) (lib.attrValues effectiveLibraries);

      # L+ (force-replace) is used instead of L (create-if-missing) because
      # Jellyfin may create an empty plugins/<name>_<version>/ directory on
      # first boot before tmpfiles runs, which would cause L to silently no-op
      # and leave the symlink uninstalled.
      #
      # Path: Jellyfin resolves PluginsPath as Path.Combine(ProgramDataPath, "plugins"),
      # where ProgramDataPath is set by --datadir, not --configdir. Mode 0700 matches
      # what Jellyfin creates itself (its systemd unit sets UMask = "0077").
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir}/plugins 0700 ${config.services.jellyfin.user} ${config.services.jellyfin.group} - -"
      ] ++ map (
        plugin: "L+ ${cfg.dataDir}/plugins/${plugin.pname}_${plugin.version} - ${config.services.jellyfin.user} ${config.services.jellyfin.group} - ${plugin}/share/${plugin.pname}"
      ) cfg.plugins;

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
        import acme_resolvers
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
