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

  # Recyclarr 8.x consumes the v8 branch of recyclarr/config-templates, which
  # uses a flat trash_id-based config (no `include:` directive). The trash_ids
  # below mirror the upstream v8 templates verbatim:
  #
  #   sonarr/templates/web-{1080p,2160p}.yml
  #   sonarr/templates/anime-remux-1080p.yml
  #   radarr/templates/sqp/sqp-1-web-{1080p,2160p}.yml
  #
  # Only the "uncommented by default" custom_format_groups are included; the
  # "uncomment to enable" optional groups (HDR boosts, language profiles, etc.)
  # are intentionally omitted.
  #
  # MAINTENANCE BURDEN
  # ------------------
  # What auto-updates (no work for us): CF regex, quality definitions, and
  # scoring tables — all live in TRaSH-Guides JSON, fetched fresh by Recyclarr
  # on each sync. We only hardcode *references*.
  #
  # What we own (drifts from upstream over time):
  #   - The literal trash_ids below
  #   - Which CF groups are enabled (mirrors the v8 templates' uncommented
  #     `add:` blocks at the time this was last refreshed)
  #   - The v8 config schema shape itself
  #
  # Expected drift cadence:
  #   - Small (renamed trash_id, new "default" CF group, new selects within a
  #     group): a few times a year. Refresh by re-reading the upstream v8
  #     template files and reconciling with the lists below.
  #   - Recyclarr major bump (e.g. v8 → v9): every 12-24 months, full module
  #     rewrite likely (this is what just happened with v7 → v8).
  #
  # Failure modes when drift hits:
  #   - TRaSH removes a trash_id → Recyclarr errors loudly on next sync.
  #   - TRaSH adds a new "default" CF group → silently missing until refresh.
  #   - TRaSH renames a CF (new trash_id) → silent scoring drift until refresh.
  #
  # Lower-maintenance alternative if drift becomes painful: vendor the v8
  # template files via a source derivation (pkgs.fetchFromGitHub of the v8
  # branch), substitute base_url/api_key, drop them in /var/lib/recyclarr/configs/.
  # Refreshes become a `rev`/`hash` bump rather than editing trash_ids by hand.
  # Switch trigger: more than ~2 manual refreshes per year.

  sonarrQualityProfileId = {
    "4K" = "d1498e7d189fbe6c7110ceaabb7473e6"; # WEB-2160p
    "1080p" = "72dae194fc92bf828f32cde7744e51a1"; # WEB-1080p
  };

  # Golden Rule differs by resolution: UHD includes "x265 (no HDR/DV)";
  # HD includes "x265 (HD)".
  sonarrGoldenRuleGroup = {
    "4K" = {
      trash_id = "e3f37512790f00d0e89e54fe5e790d1c"; # [Optional] Golden Rule UHD
      select = [ "9b64dff695c2115facf1b6ea59c9bd07" ]; # x265 (no HDR/DV)
    };
    "1080p" = {
      trash_id = "158188097a58d7687dee647e04af0da3"; # [Optional] Golden Rule HD
      select = [ "47435ece6b99a0b477caf360e79ba0bb" ]; # x265 (HD)
    };
  };

  sonarrSharedGroups = [
    {
      trash_id = "85fae4a2294965b75710ef2989c850eb"; # [Streaming Services] HD/UHD boost
      select = [
        "218e93e5702f44a68ad9e3c6ba87d2f0" # HD Streaming Boost
        "43b3cf48cb385cd3eac608ee6bca7f09" # UHD Streaming Boost
      ];
    }
    {
      trash_id = "59c3af66780d08332fdc64e68297098f"; # [Unwanted] Unwanted Formats
      select = [
        "15a05bc7c1a36e2b57fd628f8977e2fc" # AV1
        "32b367365729d530ca1c124a0b180c64" # Bad Dual Groups
        "85c61753df5da1fb2aab6f2a47426b09" # BR-DISK
        "6f808933a71bd9666531610cb8c059cc" # BR-DISK (BTN)
        "fbcb31d8dabd2a319072b84fc0b7249c" # Extras
        "9c11cd3f07101cdba90a2d81cf0e56b4" # LQ
        "e2315f990da2e2cbfc9fa5b7a6fcfe48" # LQ (Release Title)
        "23297a736ca77c0fc8e70f8edd7ee56c" # Upscaled
      ];
    }
  ];

  radarrQualityProfileId = {
    "4K" = "e91c9adaca0231493f4af0d571b907f9"; # [SQP] SQP-1 WEB (2160p)
    "1080p" = "90a3370d2d30cbaf08d9c23b856a12c8"; # [SQP] SQP-1 WEB (1080p)
  };

  # Identical for 4K and 1080p — same trash_ids in both upstream templates.
  radarrSqpUnwantedGroup = {
    trash_id = "15b1cf0b6f1a1493856a4355907affee"; # [Unwanted] Unwanted Formats SQP
    select = [
      "b6832f586342ef70d9c128d40c07b872" # Bad Dual Groups
      "cc444569854e9de0b084ab2b8b1532b2" # Black and White Editions
      "e6886871085226c3da1830830146846c" # Generated Dynamic HDR
      "bfd8eb01832d646a0a89c4deb46f8564" # Upscaled
    ];
  };

  mkSonarrMainInstance = name: arr: {
    base_url = "http://127.0.0.1:${toString arr.port}";
    api_key = {
      _secret = config.sops.secrets."${name}/api-key".path;
    };
    quality_definition.type = "series";
    quality_profiles = [
      {
        trash_id = sonarrQualityProfileId.${cfg.sonarrQuality};
        reset_unmatched_scores.enabled = true;
      }
    ];
    custom_format_groups.add = [
      sonarrGoldenRuleGroup.${cfg.sonarrQuality}
    ]
    ++ sonarrSharedGroups;
  };

  mkSonarrAnimeInstance = name: arr: {
    base_url = "http://127.0.0.1:${toString arr.port}";
    api_key = {
      _secret = config.sops.secrets."${name}/api-key".path;
    };
    quality_definition.type = "anime";
    quality_profiles = [
      {
        trash_id = "20e0fc959f1f1704bed501f23bdae76f"; # [Anime] Remux-1080p
        reset_unmatched_scores.enabled = true;
      }
    ];
    # Anime template has no uncommented custom_format_groups.
  };

  mkRadarrInstance = name: arr: {
    base_url = "http://127.0.0.1:${toString arr.port}";
    api_key = {
      _secret = config.sops.secrets."${name}/api-key".path;
    };
    quality_definition.type = "sqp-streaming";
    quality_profiles = [
      {
        trash_id = radarrQualityProfileId.${cfg.radarrQuality};
        reset_unmatched_scores.enabled = true;
      }
    ];
    custom_format_groups.add = [ radarrSqpUnwantedGroup ];
  };

  # Recyclarr v8 requires instance labels to be globally unique across all
  # services (sonarr.main + radarr.main collides). Use service-prefixed names.
  enabledSonarrs =
    lib.optionalAttrs sonarrCfg.enable {
      sonarr-main = mkSonarrMainInstance "sonarr" sonarrCfg;
    }
    // lib.optionalAttrs sonarrAnimeCfg.enable {
      sonarr-anime = mkSonarrAnimeInstance "sonarr-anime" sonarrAnimeCfg;
    };

  enabledRadarrs = lib.optionalAttrs radarrCfg.enable {
    radarr-main = mkRadarrInstance "radarr" radarrCfg;
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
