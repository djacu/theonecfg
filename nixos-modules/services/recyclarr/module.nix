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
    enum
    str
    ;

  cfg = config.theonecfg.services.recyclarr;

  sonarrCfg = config.theonecfg.services.sonarr;
  sonarrAnimeCfg = config.theonecfg.services.sonarr-anime;
  radarrCfg = config.theonecfg.services.radarr;

  # Recyclarr templates (https://github.com/recyclarr/config-templates).
  # The plan locked in 4K (UHD) defaults.
  sonarrTemplate = if cfg.sonarrQuality == "4K" then "web-2160p-v4" else "web-1080p-v4";
  sonarrAnimeTemplate = "anime-sonarr-v4";
  radarrTemplate = if cfg.radarrQuality == "4K" then "sqp/sqp-1-web-2160p" else "sqp/sqp-1-web-1080p";

  mkSonarrInstance = name: arr: {
    base_url = "http://127.0.0.1:${toString arr.port}";
    api_key = {
      _secret = config.sops.secrets."${name}/api-key".path;
    };
    include = [
      { template = if name == "sonarr-anime" then sonarrAnimeTemplate else sonarrTemplate; }
    ];
  };

  mkRadarrInstance = name: arr: {
    base_url = "http://127.0.0.1:${toString arr.port}";
    api_key = {
      _secret = config.sops.secrets."${name}/api-key".path;
    };
    include = [ { template = radarrTemplate; } ];
  };

  enabledSonarrs =
    lib.optionalAttrs sonarrCfg.enable {
      main = mkSonarrInstance "sonarr" sonarrCfg;
    }
    // lib.optionalAttrs sonarrAnimeCfg.enable {
      anime = mkSonarrInstance "sonarr-anime" sonarrAnimeCfg;
    };

  enabledRadarrs = lib.optionalAttrs radarrCfg.enable {
    main = mkRadarrInstance "radarr" radarrCfg;
  };

in
{
  options.theonecfg.services.recyclarr = {
    enable = mkEnableOption "Recyclarr (TRaSH-Guides quality profile + custom format sync)";
    sonarrQuality = mkOption {
      type = enum [
        "1080p"
        "4K"
      ];
      default = "4K";
      description = "Quality preset for Sonarr (main instance). Anime always uses the anime preset.";
    };
    radarrQuality = mkOption {
      type = enum [
        "1080p"
        "4K"
      ];
      default = "4K";
    };
    schedule = mkOption {
      type = str;
      default = "daily";
      description = "systemd OnCalendar expression for the sync timer.";
    };
  };

  config = mkIf cfg.enable {
    services.recyclarr = {
      enable = true;
      schedule = cfg.schedule;
      configuration =
        lib.optionalAttrs (enabledSonarrs != { }) { sonarr = enabledSonarrs; }
        // lib.optionalAttrs (enabledRadarrs != { }) { radarr = enabledRadarrs; };
    };

    # Recyclarr's NixOS module uses systemd LoadCredential to copy each
    # _secret-referenced file into the recyclarr service's credential
    # directory at runtime. systemd LoadCredential runs as root, so it can
    # read sops-managed files regardless of their permissions.
  };
}
