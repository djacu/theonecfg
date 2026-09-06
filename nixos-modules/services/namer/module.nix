{
  config,
  lib,
  pkgs,
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
    anything
    attrsOf
    bool
    int
    listOf
    str
    ;

  cfg = config.theonecfg.services.namer;
  qbtCfg = config.theonecfg.services.qbittorrent;
  whisparrCfg = config.theonecfg.services.whisparr;

  # namer reads its config from the file named by NAMER_CONFIG (the only
  # config mechanism for `namer watchdog` — the subcommand has no -c flag).
  # IMPORTANT: namer.cfg.default (bundled in the package), not the
  # configuration.py dataclass, is the effective-defaults layer. Every pin
  # below that restates an apparent "default" exists because the bundled
  # cfg overrides the dataclass (update_permissions_ownership=True,
  # retry_time=<empty>, web=False, ...). See the design doc,
  # "Effective-default traps". Do not remove pins.
  #
  # namer's parser ignores EMPTY values (cannot clear a nonempty default,
  # only replace it) — so never render an empty string here.
  namerSettings = lib.recursiveUpdate {
    namer = {
      porndb_token = config.sops.placeholder."namer/tpdb-token";
      # Whisparr-parseable shape; used for `namer rename` CLI runs.
      inplace_name = "{full_site} - {date} - {name} [WEBDL-{resolution}].{ext}";
      # Default 300 (MiB) would silently skip short scenes.
      min_file_size = 0;
      write_namer_log = false;
      # Failed-side json.gz sidecars power the web UI's match% columns and
      # are cleaned up by namer's retry/success/delete paths. Keep them.
      write_namer_failed_log = true;
      target_extensions = lib.concatStringsSep "," cfg.videoExtensions;
      # LOAD-BEARING: effective default is True — namer would lchown/chmod
      # the qbt-owned shared inode, hit PermissionError, and strand files
      # in work/.
      update_permissions_ownership = false;
      database_path = cfg.dataDir;
      # Phash cache (keyed name,size,mtime — survives retry cycles and the
      # work/-sweep below) + requests cache.
      use_database = true;
      use_requests_cache = true;
      # convert_container_to MUST stay unset: it re-muxes into a NEW inode
      # (a full data copy on the downloads dataset + a broken inode
      # mapping). Absent here = namer's empty default = disabled.
    };
    Phash = {
      search_phash = true;
      # The Go videohashes tool (bundled) is the Stash-compatible hasher;
      # the pure-python alternative is "not 100% compatible" with TPDb.
      use_alt_phash_tool = false;
    };
    metadata = {
      # Tagging/posters write the shared inode → would corrupt the seeding
      # copy through the hardlink. Effective defaults are already false;
      # pinned so an upstream flip can't hurt.
      enabled_tagging = false;
      enabled_poster = false;
    };
    duplicates = {
      # If false, namer silently unlinks "losing" duplicates in dest/.
      preserve_duplicates = true;
    };
    watchdog = {
      del_other_files = false;
      queue_limit = 0;
      # The watchdog's dest naming key (NOT inplace_name). Default contains
      # a {full_site}/ subdirectory; pinned FLAT so the shuttle's harvest
      # is a flat scan of dest/.
      new_relative_path_name = "{full_site} - {date} - {name} [WEBDL-{resolution}].{ext}";
      watch_dir = "${cfg.scratchDir}/watch";
      work_dir = "${cfg.scratchDir}/work";
      failed_dir = "${cfg.scratchDir}/failed";
      dest_dir = "${cfg.scratchDir}/dest";
      # LOAD-BEARING: the shipped empty default means NO daily failed/
      # retry ever runs (the "random 3am" fallback is dead code). 03:17 =
      # dead hour, avoids racing a human in the web UI.
      retry_time = "03:17";
      # Web UI is OFF by effective default; it is the manual-match surface
      # for residuals.
      web = true;
      host = "127.0.0.1";
      port = cfg.port;
      # Delete button in the web UI, scoped by namer to failed_dir. Deleting
      # a failed entry whose torrent is gone frees the pinned bytes; while
      # the torrent lives it just opts the file out of auto-matching (the
      # shuttle's state remembers it was fed and never re-feeds).
      allow_delete_files = true;
    };
  } cfg.settings;

  # Match namer.cfg.default's True/False literal style.
  toNamerIni = lib.generators.toINI {
    mkKeyValue = lib.generators.mkKeyValueDefault {
      mkValueString =
        v:
        if lib.isBool v then (if v then "True" else "False") else lib.generators.mkValueStringDefault { } v;
    } " = ";
  };

  # Files move watch→work at DETECTION time and namer refuses to start
  # (sys.exit -1) when work/ holds >1 MiB — a restart mid-burst would
  # crash-loop without this sweep. Same-fs renames; the shuttle's state is
  # inode-keyed and the phash cache is (name,size,mtime)-keyed, so nothing
  # is lost or recomputed. A same-named watch/ entry can only be the same
  # inode (link names are unique per download+path), so it's safe to drop
  # the work/ copy in that case.
  workSweep = pkgs.writeShellApplication {
    name = "namer-work-sweep";
    text = ''
      shopt -s nullglob dotglob
      for f in ${cfg.scratchDir}/work/*; do
        b=$(basename "$f")
        if [ -e "${cfg.scratchDir}/watch/$b" ]; then
          if [ "$f" -ef "${cfg.scratchDir}/watch/$b" ]; then
            rm -- "$f"
          else
            echo "namer-work-sweep: name collision, leaving $f" >&2
          fi
        else
          mv -- "$f" "${cfg.scratchDir}/watch/"
        fi
      done
    '';
  };

  shuttleBin = pkgs.writers.writePython3Bin "whisparr-namer-shuttle" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./shuttle.py);

in
{
  options.theonecfg.services.namer = {
    enable = mkEnableOption "namer (phash-based import rescue for Whisparr)";
    scratchDir = mkOption {
      type = str;
      default = "${qbtCfg.downloadsDir}/.namer";
      description = ''
        Watch/work/failed/dest scratch area. MUST live on the same
        filesystem as the qBittorrent downloads (the pipeline is built on
        hardlinks); hence the default derives from
        ``theonecfg.services.qbittorrent.downloadsDir``.
      '';
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/namer";
      description = "Phash DB, requests cache, and shuttle state.";
    };
    port = mkOption {
      type = int;
      default = 6980;
    };
    domain = mkOption {
      type = str;
      default = "namer.${config.theonecfg.networking.lanDomain}";
    };
    videoExtensions = mkOption {
      type = listOf str;
      default = [
        "mp4"
        "mkv"
        "avi"
        "mov"
        "flv"
        "wmv"
        "m4v"
        "ts"
        "webm"
        "mpg"
        "mpeg"
      ];
      description = ''
        Extensions namer will process (its default list silently ignores
        anything else). The shuttle uses the same list to classify
        unsupported files it still pins.
      '';
    };
    settings = mkOption {
      type = attrsOf (attrsOf anything);
      default = { };
      description = ''
        Freeform INI overlay merged over the pinned defaults
        (section → key → value). namer's parser ignores empty values —
        you cannot clear a nonempty default, only replace it.
      '';
    };
    shuttle = {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Whisparr feed/harvest shuttle (needs whisparr enabled).";
      };
      interval = mkOption {
        type = str;
        default = "hourly";
        description = "systemd OnCalendar expression for the shuttle timer.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      users.users.namer = {
        isSystemUser = true;
        group = "namer";
        extraGroups = [ "media" ];
        home = cfg.dataDir;
      };
      users.groups.namer = { };

      sops.secrets."namer/tpdb-token".owner = "namer";

      sops.templates."namer.cfg" = {
        content = toNamerIni namerSettings;
        owner = "namer";
      };

      # namer creates none of its dirs (its config verify exits if any is
      # missing). dataDir is namer-private and root-owned above it, so
      # tmpfiles can manage it directly. Scratch dirs are created by a
      # root ExecStartPre instead (see systemd.services.namer below):
      # tmpfiles' unsafe-path-transition guard refuses to nest a
      # namer-owned entry under the qbittorrent-owned downloads root.
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 namer namer - -"
      ];

      systemd.services.namer = {
        description = "namer watchdog (phash matcher + web UI)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment.NAMER_CONFIG = config.sops.templates."namer.cfg".path;
        serviceConfig = {
          ExecStartPre = [
            # tmpfiles cannot manage these: its unsafe-path-transition
            # guard refuses namer-owned entries nested under the
            # qbittorrent-owned downloads root (cross-user nesting is the
            # whole point here — the scratch area must share the downloads
            # filesystem for hardlinks). Create them privileged instead;
            # RequiresMountsFor has already mounted the filesystem.
            "+${pkgs.coreutils}/bin/install -d -m 2775 -o namer -g media ${cfg.scratchDir} ${cfg.scratchDir}/watch ${cfg.scratchDir}/work ${cfg.scratchDir}/failed ${cfg.scratchDir}/dest"
            "${workSweep}/bin/namer-work-sweep"
          ];
          ExecStart = "${pkgs.namer}/bin/namer watchdog";
          User = "namer";
          Group = "namer";
          SupplementaryGroups = [ "media" ];
          # namer exits nonzero when TPDb is unreachable at startup.
          Restart = "on-failure";
          RestartSec = "30s";

          # Hardening (cloned from sonarr-anime / upstream services.sonarr,
          # minus its trailing "@chown" — namer must never chown: content
          # mutation through the shared inode corrupts seeding), plus
          # ProtectSystem=strict + ReadWritePaths scoped to scratch and
          # state — without ProtectSystem, ReadWritePaths is a no-op.
          ProtectSystem = "strict";
          ReadWritePaths = [
            cfg.scratchDir
            cfg.dataDir
          ];
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          ProtectHome = true;
          ProtectClock = true;
          ProtectKernelLogs = true;
          PrivateTmp = true;
          PrivateDevices = true;
          PrivateUsers = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          RemoveIPC = true;
          UMask = "0022";
          ProtectHostname = true;
          ProtectProc = "invisible";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
            "~@debug"
            "~@mount"
          ];
        };
        unitConfig.RequiresMountsFor = [
          cfg.scratchDir
          cfg.dataDir
        ];
      };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })

    (mkIf (cfg.shuttle.enable && whisparrCfg.enable) {
      # Read-only reuse of the existing whisparr/api-key sops entry under a
      # different owner (sops-nix `key` aliasing; single yaml entry).
      sops.secrets."whisparr/api-key-namer" = {
        key = "whisparr/api-key";
        owner = "namer";
      };

      systemd.services.whisparr-namer-shuttle = {
        description = "Feed Whisparr's import-blocked files to namer and import the matches";
        # after= only (no requires=): if whisparr is down the sweep exits 1
        # and Persistent=true retries next tick — no need to drag units up.
        after = [
          "namer.service"
          "whisparr.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${shuttleBin}/bin/whisparr-namer-shuttle";
          User = "namer";
          Group = "namer";
          SupplementaryGroups = [ "media" ];
        };
        environment = {
          WHISPARR_URL = "http://127.0.0.1:${toString whisparrCfg.port}";
          WHISPARR_API_KEY_FILE = config.sops.secrets."whisparr/api-key-namer".path;
          SCRATCH_DIR = cfg.scratchDir;
          STATE_FILE = "${cfg.dataDir}/shuttle-state.json";
          TARGET_EXTENSIONS = lib.concatStringsSep "," cfg.videoExtensions;
        };
        unitConfig.RequiresMountsFor = [
          cfg.scratchDir
          cfg.dataDir
        ];
      };

      systemd.timers.whisparr-namer-shuttle = {
        description = "Hourly whisparr-namer shuttle sweep";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.shuttle.interval;
          RandomizedDelaySec = "5m";
          Persistent = true;
        };
      };
    })
  ]);
}
