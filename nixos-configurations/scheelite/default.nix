inputs: {
  release = rec {
    number = "unstable";
    nixpkgs = inputs."nixpkgs-${number}";
  };
  modules =
    {
      config,
      lib,
      pkgs,
      theonecfg,
      ...
    }:
    let
      # Path prefixes for tank0-resident state and media. Modules default
      # to /var/lib/<svc> for portability; scheelite overrides to put
      # service state on the bulk pool.
      tankServicesDir = "/tank0/services";
      tankMediaDir = "/tank0/media";
      tankDownloadsDir = "/tank0/downloads";

      declarative = theonecfg.library.declarative pkgs;
    in
    {
      imports = [
        ./disko.nix
        ./hardware.nix
        ./impermanence.nix
      ];
      config = {
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "24.05";

        # Hardlink identical files in /nix/store inline during writes.
        # Captures the dominant /nix/store duplication at file level, so the
        # local/nix dataset can stay dedup=off (avoids DDT RAM cost).
        nix.settings.auto-optimise-store = true;

        # Base LAN domain. Each service's `domain` defaults to <svc>.<this>;
        # AdGuard's wildcard rewrite covers *.<this>. Real domain registered
        # at Porkbun + Let's Encrypt DNS-01 issuing certs (see Caddy module),
        # so browsers/services trust the certs natively — no per-device CA
        # install needed. Subdomains aren't published in public DNS, so they
        # only resolve via AdGuard on the LAN.
        theonecfg.networking.lanDomain = "scheelite.dev";

        # Use the systemd-boot EFI boot loader.
        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.efi.efiSysMountPoint = "/boot";

        # ZFS
        boot.kernelPackages = pkgs.linuxPackages_6_18;
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.devNodes = "/dev/disk/by-id";
        boot.zfs.extraPools = [ "scheelite-tank0" ];
        services.zfs.autoScrub.enable = true;
        boot.initrd.systemd.services.rollback-root = {
          description = "Rollback ZFS root to empty snapshot";
          wantedBy = [ "initrd.target" ];
          after = [ "zfs-import-scheelite-root.service" ];
          before = [ "sysroot.mount" ];
          unitConfig.DefaultDependencies = "no";
          serviceConfig.Type = "oneshot";
          path = [ config.boot.zfs.package ];
          script = ''
            zfs rollback -r scheelite-root/local/root@empty && echo "rollback of scheelite-root complete"
          '';
        };

        networking.hostId = lib.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

        security.sudo.extraConfig = ''
          # rollback results in sudo lectures after each reboot
          Defaults lecture = never
        '';

        time.timeZone = "America/Los_Angeles";

        users.mutableUsers = false;
        users.users.root.initialHashedPassword = "$6$efX.JpKjAey2jrYG$kOt..AuFrPPIVTDncVj7vNkIo4MR/9mYG2SaDV2xpSNDEmk8DRxVNmuMI6hcW.CmD6ZDqdIKCj2MAyHnIdrkl/";

        # Static IP on the VLAN_10_DAN VLAN (pfSense access port untags it,
        # so scheelite sees plain Ethernet on eno1). Chosen outside the
        # VLAN's DHCP pool (10.0.10.10–.100) and clear of existing static
        # reservations (.101, .120). Putting it on the host instead of as
        # a router DHCP reservation keeps scheelite's networking
        # independent of the router (we may swap pfSense for a NixOS-based
        # router later).
        networking.useDHCP = false;
        networking.interfaces.eno1.ipv4.addresses = [
          {
            address = "10.0.10.111";
            prefixLength = 24;
          }
        ];
        networking.defaultGateway = "10.0.10.1";
        # Local AdGuard is the primary resolver so *.<lanDomain>
        # rewrites work for processes on this host. Cloudflare
        # follows as fallback if AdGuard is briefly unavailable
        # (won't resolve LAN domains, but external lookups still work).
        networking.nameservers = [
          "127.0.0.1"
          "1.1.1.1"
          "1.0.0.1"
        ];

        # AdGuard reads /etc/hosts on this host and serves it to any LAN
        # client using scheelite as DNS. NixOS's default loopback alias
        # (`127.0.0.2 scheelite`) would tell every other machine that
        # "scheelite" lives on their own loopback — useless. Drop the alias
        # and map the hostname to its real LAN IP instead so all clients
        # get a reachable address.
        networking.hosts = {
          "127.0.0.2" = lib.mkForce [ ];
          "${(builtins.head config.networking.interfaces.eno1.ipv4.addresses).address}" = [
            config.networking.hostName
          ];
        };

        theonecfg.profiles.common.enable = true;
        theonecfg.profiles.server.enable = true;

        theonecfg.users.djacu.enable = true;
        users.users.djacu.initialHashedPassword = "$y$j9T$W5JJISgEkrLM1NRu.uGR4/$2GXSsgkFimX46x.h.MqUEiLCuWl9kmV0dJoZtX6e78/";

        # Homelab services (see docs/plans/active/scheelite-homelab-services.md).
        # All disabled until prerequisites are in place. Enable phase-by-phase.
        theonecfg.services = {
          # --- Phase 1: foundation ---
          # Prerequisites: secrets/scheelite.yaml exists with the keys named in each
          # module's sops.secrets.* entries; ZFS datasets created on tank0; router
          # DHCP advertises (scheelite-IP, 1.1.1.1) as DNS.
          sops.enable = true;
          caddy = {
            enable = true;
            acmeEmail = theonecfg.knownUsers.djacu.email;
          };
          adguard = {
            enable = true;
            # Read directly from the static address set on eno1 above.
            # Single source of truth — change the IP in one place.
            lanIp = (builtins.head config.networking.interfaces.eno1.ipv4.addresses).address;
          };
          postgres = {
            enable = true;
            # Per-instance postgres datasets live under /persist so they
            # survive root rollback. The dedicated ZFS datasets at
            # /persist/postgres/<instance> set recordsize=16K (see disko.nix).
            instancesDir = "/persist/postgres";
          };

          # --- Phase 2: identity ---
          # Prerequisites: kanidm/admin and kanidm/idm-admin in scheelite.yaml.
          kanidm = {
            enable = true;
            person = theonecfg.knownUsers.djacu.username;
          };
          oauth2-proxy.enable = true;

          # --- Phase 3: media (declarative via REST one-shots + Recyclarr) ---
          # See docs/plans/active/scheelite-declarative-arr.md for the
          # four-layer approach. Each module reads its API key from sops
          # via env-var injection (Sonarr__Auth__ApiKey etc.).
          jellyfin = {
            enable = true;
            dataDir = "${tankServicesDir}/jellyfin";
            cacheDir = "${tankServicesDir}/jellyfin-cache";
            adminUser = theonecfg.knownUsers.djacu.username;
          };
          qbittorrent = {
            enable = true;
            profileDir = "${tankServicesDir}/qbittorrent";
            downloadsDir = tankDownloadsDir;
            # Save-path for releases that Prowlarr grabs directly from
            # its UI (i.e. not via an *arr). Manual grabs land here
            # before the user sorts/imports them somewhere.
            extraCategories.prowlarr = "${tankDownloadsDir}/prowlarr";
          };
          # prowlarrTags follow a content-type taxonomy: each app's tag list
          # describes what it consumes; each indexer's tag list (below) describes
          # what it serves. Prowlarr's intersect rule routes accordingly.
          # Taxonomy: tv | movies | anime | adult | music | books.
          sonarr = {
            enable = true;
            dataDir = "${tankServicesDir}/sonarr";
            rootFolders = [ { path = "${tankMediaDir}/tv"; } ];
            prowlarrTags = [ "tv" ];
          };
          sonarr-anime = {
            enable = true;
            dataDir = "${tankServicesDir}/sonarr-anime";
            rootFolders = [ { path = "${tankMediaDir}/anime"; } ];
            prowlarrTags = [ "anime" ];
          };
          radarr = {
            enable = true;
            dataDir = "${tankServicesDir}/radarr";
            rootFolders = [ { path = "${tankMediaDir}/movies"; } ];
            prowlarrTags = [ "movies" ];
          };
          whisparr = {
            enable = true;
            dataDir = "${tankServicesDir}/whisparr";
            rootFolders = [ { path = "${tankMediaDir}/adult"; } ];
            prowlarrTags = [ "adult" ];
          };
          prowlarr = {
            enable = true;
            dataDir = "${tankServicesDir}/prowlarr";
            # Public Cardigann indexers — no auth, work without FlareSolverr
            # (verified May 2026; 1337x and TorrentGalaxy are CF-blocked and
            # excluded). Tagged anime/adult routes to sonarr-anime / whisparr
            # respectively (prowlarrTags above match these labels).
            # Empornium is a private adult tracker the user has an account
            # on; deferred to a follow-up commit once empornium/* are added
            # to secrets/scheelite.yaml.
            # Each indexer is tagged with every content type it advertises.
            # See `theonecfg.services.<arr>.prowlarrTags` above for app-side
            # consumption tags and the routing taxonomy.
            indexers = [
              # EZTV dropped — eztvx.to is Cloudflare-protected in 2026; can
              # revisit once FlareSolverr or a configurable mirror works.
              (declarative.mkCardigannIndexer {
                name = "YTS";
                definitionFile = "yts";
                tags = [ "movies" ];
              })
              (declarative.mkCardigannIndexer {
                name = "LimeTorrents";
                definitionFile = "limetorrents";
                # LimeTorrents advertises TV+Movies+Music+Books+anime
                # subcategory per its schema. Tagged with everything; future
                # Lidarr/Readarr will pick it up automatically.
                tags = [
                  "tv"
                  "movies"
                  "anime"
                  "music"
                  "books"
                ];
              })
              # kickasstorrents.ws dropped — Cloudflare-blocked in 2026
              # ("Unable to access kickass.ws, blocked by CloudFlare
              # Protection." per Prowlarr POST 400). Same revisit conditions
              # as EZTV.
              (declarative.mkCardigannIndexer {
                name = "Nyaa.si";
                definitionFile = "nyaasi";
                tags = [ "anime" ];
              })
              (declarative.mkCardigannIndexer {
                name = "sukebei.nyaa.si";
                definitionFile = "sukebeinyaasi";
                tags = [ "adult" ];
              })
              # Empornium — private adult tracker. Username/password injected
              # at runtime from sops via the `_usernameFile`/`_passwordFile`
              # markers that mkArrApiPushService's secret-injection step
              # resolves. The 2FA variant is `empornium2fa` if needed later.
              (declarative.mkCardigannIndexerWithCreds {
                name = "Empornium";
                definitionFile = "empornium";
                usernameFile = config.sops.secrets."empornium/username".path;
                passwordFile = config.sops.secrets."empornium/password".path;
                tags = [ "adult" ];
              })
            ];
            # Prowlarr's own download client — only used when grabbing
            # releases directly from Prowlarr's UI (the *arrs each have
            # their own qBittorrent client, pushed via the *arr's own
            # download-clients reconciler). Without this, Prowlarr UI
            # grabs fail with `DownloadClientUnavailableException:
            # Torrent Download client isn't configured yet`. The
            # `prowlarr` category routes to ${tankDownloadsDir}/prowlarr
            # via qbittorrent.extraCategories above.
            downloadClients = [
              (declarative.mkQbtDownloadClient {
                port = config.theonecfg.services.qbittorrent.webUiPort;
                category = "prowlarr";
                variant = "prowlarr";
              })
            ];
          };
          pinchflat = {
            enable = false;
            mediaDir = "${tankMediaDir}/youtube";
          };
          recyclarr.enable = true;
          jellyseerr.enable = true;

          # --- Phase 4: apps with DBs ---
          # Each enables its own postgres instance (defined in the service module).
          # Prerequisites: <app>/admin-password and <app>/db-password (where used)
          # plus kanidm/oauth-<app> for OIDC.
          nextcloud = {
            enable = false;
            dataDir = "${tankServicesDir}/nextcloud";
          };
          immich = {
            enable = false;
            mediaLocation = "${tankMediaDir}/photos";
          };
          paperless = {
            enable = true;
            dataDir = "${tankServicesDir}/paperless";
            mediaDir = "${tankServicesDir}/paperless/media";
            consumptionDir = "${tankServicesDir}/paperless/consume";
          };

          # --- Phase 5: monitoring ---
          monitoring.prometheus.enable = true;
          monitoring.node-exporter.enable = true;
          monitoring.zfs-exporter.enable = true;
          # SAS drive temperatures via smartctl_exporter — Scrutiny's
          # collector (0.8.6/0.9.2) parses SAS temps as null and the UI
          # shows them as ∞; this exporter feeds the same data into
          # Prometheus where Grafana can graph it correctly.
          monitoring.smartctl-exporter.enable = true;
          monitoring.loki = {
            enable = true;
            dataDir = "${tankServicesDir}/loki";
          };
          monitoring.alloy.enable = true;
          monitoring.grafana.enable = true;
          monitoring.scrutiny.enable = true;

          # --- Phase 6: dashboard (per scheelite-homepage-dashboard.md) ---
          # Glances supplies system-stats to the Homepage `glances`
          # widget on loopback and serves its own UI on glances.<lan>.
          # Homepage auto-derives every tile from the enabled services
          # above.
          glances.enable = true;
          homepage.enable = true;
        };

        # Indexer-specific credentials (sops). These live in the host
        # config rather than the prowlarr module because they're tied to
        # specific indexer entries declared above (Empornium); we'd
        # populate per-host on a per-tracker basis.
        sops.secrets."empornium/username".owner = "prowlarr";
        sops.secrets."empornium/password".owner = "prowlarr";
      };
    };
}
