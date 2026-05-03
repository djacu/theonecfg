# Plan: scheelite homelab services (initial design)

**Status:** Active
**Started:** 2026-04-26
**Last revised:** 2026-04-27
**Owner:** djacu
**Companion docs:**

- `scheelite-declarative-arr.md` — four-layer pattern for \*arr / Jellyfin / qBittorrent declarative config
- `scheelite-tank0-layout.md` — disko-managed pool + dataset hierarchy (TODO; covered inline below for now)
- `scheelite-backup-options.md` — deferred backup design discussion
- `scheelite-external-access-options.md` — deferred external-access discussion

## Context

`scheelite` is the homelab server (AMD Ryzen 7950X on ASUS PRIME X670E-PRO,
2× Samsung 990 Pro 2 TB NVMe boot mirror, 8× HGST raidz3 bulk pool via LSI
HBA, ZFS root with impermanence). Currently runs only system-level services
(openssh, pcscd, zfs autoscrub) — no user-facing services.

This plan adds a curated set of homelab services as new NixOS modules under
`nixos-modules/services/`, following the repo's existing conventions:

- Auto-import via `getDirectoryNames` (same pattern as `home-modules/services/module.nix:19-25`)
- Namespace `theonecfg.services.<name>`
- `mkEnableOption` + `mkIf cfg.enable` skeleton (template at
  `home-modules/programs/fish/module.nix:1-29` and
  `nixos-modules/profiles/server/module.nix:1-34`)
- Prefer upstream NixOS modules; layer thin opinionated wrappers, don't reimplement.
  Always check what the upstream module already does (tmpfiles, RequiresMountsFor,
  StateDirectory, etc.) before duplicating it in the wrapper.

Initial in-scope services:

- **Media**: Jellyfin, qBittorrent, Sonarr, Sonarr-anime (second instance), Radarr,
  Whisparr, Prowlarr, Pinchflat, Recyclarr, Jellyseerr (services.seerr in 26.05)
- **Cloud / files**: Nextcloud
- **Photos**: Immich
- **Documents**: Paperless-ngx
- **Identity / auth (LAN-only this iteration)**: Kanidm + oauth2-proxy
- **Foundational**: Caddy (reverse proxy), AdGuard Home (LAN DNS + ad blocking),
  sops-nix (secrets)
- **Monitoring**: Prometheus, Grafana, Loki + Grafana Alloy (log shipping),
  Scrutiny, node_exporter, zfs_exporter

## Locked decisions

| Topic | Decision |
|---|---|
| Service isolation | Native systemd services on scheelite; postgres backings run in NixOS containers (per-service instance) |
| Per-service postgres | One `containers.postgres-<svc>` per service that needs a DB; bind-mounted to a dedicated ZFS dataset at `/persist/postgres/<svc>` (recordsize=8K) |
| Local routing | Subdomain-based on `*.scheelite.lan`, served by Caddy |
| Local DNS | AdGuard Home with wildcard rewrite `*.scheelite.lan → <scheelite IP>`; router DHCP advertises (scheelite, 1.1.1.1) so reboots fall back |
| Identity | Kanidm as IdP. OIDC-aware services integrate natively. Non-OIDC services sit behind oauth2-proxy as forward-auth, validating Kanidm tokens |
| Secrets | sops-nix. Encrypted to scheelite's persisted host SSH key + user's age key for editing |
| Storage layout | Hierarchical via disko: boot pool emits root + per-instance postgres datasets; tank0 emits `/tank0/media/{tv,anime,movies,adult,music,audiobooks,books,photos,youtube}`, `/tank0/downloads`, `/tank0/services/<svc>`. See `nixos-configurations/scheelite/disko.nix`. |
| Disko import | `disko.nix` in repo but not yet imported in `scheelite/default.nix` (conflicts with existing `hardware.nix` filesystem entries). Import after a clean nixos-anywhere reinstall. |
| Declarative \*arr/Jellyfin config | Four layers: upstream `services.<svc>` + env-var injection from sops + Recyclarr + custom REST one-shots. **Goal: zero web-UI clicks after deploy.** See `scheelite-declarative-arr.md`. |
| Recyclarr quality default | 4K (UHD): `web-2160p-v4` for Sonarr, `anime-sonarr-v4` for sonarr-anime, `sqp/sqp-1-web-2160p` for Radarr |
| qBittorrent password (B-lite) | Localhost auth bypass for the loopback path (Caddy + our one-shots); PBKDF2 password seeded into `qBittorrent.conf` at preStart from sops plaintext, as defense in depth against accidental LAN-binding |
| Log shipping | Grafana Alloy (replaces deprecated promtail; `services.alloy` config in `/etc/alloy/config.alloy`) |
| External access | **POSTPONED** — captured in `scheelite-external-access-options.md` |
| Backups | **DEFERRED** — captured in `scheelite-backup-options.md` |
| Vaultwarden | **DEFERRED** — depends on backup design landing first |
| Reverse proxy | Caddy (over nginx) for simpler config and automatic ACME |
| VPN namespace for downloads | Out of scope this iteration |
| Usenet (SABnzbd, NZBGet) | Out of scope — torrents only |

## Module layout

All auto-imported by an existing `getDirectoryNames` pattern (no manual wiring):

```text
nixos-modules/services/
├── module.nix                  # auto-import boilerplate
├── caddy/module.nix            # reverse proxy
├── adguard/module.nix          # LAN DNS + ad blocking
├── sops/module.nix             # sops-nix host wiring
├── postgres/module.nix         # per-service postgres-in-container helper
├── kanidm/module.nix           # IdP server + provisioning
├── oauth2-proxy/module.nix     # forward-auth gateway for non-OIDC services
├── jellyfin/module.nix         # /Startup/* bootstrap + auto-derived libraries
├── qbittorrent/module.nix      # serverConfig + PBKDF2 preStart + auto-derived categories
├── sonarr/module.nix           # env-var auth + declarative root folders / DLs / delay profiles
├── sonarr-anime/module.nix     # second Sonarr instance (anime workflow)
├── radarr/module.nix
├── whisparr/module.nix
├── prowlarr/module.nix         # auto-linked to enabled *arr instances
├── pinchflat/module.nix
├── recyclarr/module.nix        # TRaSH-Guides quality profiles + custom formats
├── jellyseerr/module.nix       # services.seerr; admin bootstrap via Jellyfin auth
├── nextcloud/module.nix
├── immich/module.nix
├── paperless/module.nix
└── monitoring/
    ├── module.nix
    ├── prometheus/module.nix
    ├── grafana/module.nix
    ├── loki/module.nix
    ├── alloy/module.nix        # ships journald logs to Loki
    ├── scrutiny/module.nix
    ├── node-exporter/module.nix
    └── zfs-exporter/module.nix
```

Common per-service module skeleton (existing convention):

```nix
{ config, lib, pkgs, theonecfg, ... }:
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) str int;
  cfg = config.theonecfg.services.<name>;
in {
  options.theonecfg.services.<name> = {
    enable = mkEnableOption "<name>";
    domain = mkOption { type = str; default = "<name>.scheelite.lan"; };
    port   = mkOption { type = int; default = <upstream default>; };
  };
  config = mkIf cfg.enable (mkMerge [
    { services.<name> = { enable = true; ... }; }
    (mkIf config.theonecfg.services.caddy.enable { /* register Caddy vhost */ })
  ]);
}
```

## Storage / persistence

### Disko-managed (target state)

`nixos-configurations/scheelite/disko.nix` declares both pools and the
complete dataset hierarchy with per-dataset properties (recordsize,
compression, atime, mountpoint). It is **not yet imported** in
`scheelite/default.nix` because importing it conflicts with the
manually-set `fileSystems` entries currently in `hardware.nix`.

**Migration path:**

1. Boot from a NixOS installer with this flake checked out.
1. `nixos-anywhere --flake .#scheelite root@<scheelite-ip>` (will wipe
   and re-create both pools per `disko.nix`; destroys all existing data).
1. After install: edit `scheelite/default.nix` to import `./disko.nix`
   and remove the now-redundant `fileSystems` and `swapDevices` entries
   from `hardware.nix`.

The user has stated scheelite is not yet running anything important, so
the wipe-and-reinstall path is acceptable.

### Layout summary

```
scheelite-root              POOL on dual-NVMe mirror (Samsung 990 Pro 2TB ×2)
├── local                   recordsize=128K, atime=off, compression=lz4
│   ├── root                /                 ephemeral; rolled back to empty on boot
│   └── nix                 /nix
└── safe
    ├── home                /home
    └── persist             /persist          impermanence target
        └── postgres                          parent (canmount=off)
            ├── nextcloud   /persist/postgres/nextcloud   recordsize=8K
            ├── immich      /persist/postgres/immich      recordsize=8K
            ├── paperless   /persist/postgres/paperless   recordsize=8K
            ├── sonarr      /persist/postgres/sonarr      recordsize=8K
            ├── sonarr-anime /persist/postgres/sonarr-anime recordsize=8K
            ├── radarr      /persist/postgres/radarr      recordsize=8K
            ├── whisparr    /persist/postgres/whisparr    recordsize=8K
            └── prowlarr    /persist/postgres/prowlarr    recordsize=8K

scheelite-tank0             POOL on HGST ×8 raidz3 via LSI HBA
└── tank0                   /tank0           recordsize=128K, atime=off, compression=lz4
    ├── media               /tank0/media     recordsize=1M, compression=zstd-1
    │   ├── tv              → Sonarr
    │   ├── anime           → Sonarr-anime
    │   ├── movies          → Radarr
    │   ├── adult           → Whisparr
    │   ├── music           → Lidarr (future)
    │   ├── audiobooks      → Audiobookshelf (future)
    │   ├── books           → Readarr (future)
    │   ├── photos          → Immich library
    │   └── youtube         → Pinchflat
    ├── downloads           /tank0/downloads recordsize=1M, compression=off  → qBittorrent
    └── services            /tank0/services  recordsize=128K
        ├── jellyfin
        ├── jellyfin-cache  separate dataset; sanoid policy can exclude
        ├── sonarr
        ├── sonarr-anime
        ├── radarr
        ├── whisparr
        ├── qbittorrent
        ├── nextcloud
        ├── paperless
        ├── grafana
        ├── prometheus
        └── loki
```

### Persistence (`nixos-configurations/scheelite/impermanence.nix`)

Add to `environment.persistence."/persist".directories`:

- `/var/lib/AdGuardHome`
- `/var/lib/caddy`
- `/var/lib/private/kanidm`
- `/var/lib/oauth2_proxy`
- `/var/lib/grafana`
- `/var/lib/loki`
- `/var/lib/prometheus2`
- `/var/lib/nixos-containers`
- `/var/lib/sops-nix`
- `/var/lib/seerr`
- `/var/lib/recyclarr`

App-level data lives on `/tank0/services/<name>` and survives rollback by being
on a separate ZFS dataset (not impermanence-tracked).

`/persist/postgres/<service>` (per-service postgres data dirs) lives on
its own dataset under `safe/persist/postgres/<svc>` — no impermanence entry
needed because the dataset is already persistent by virtue of being on the
boot pool's `safe` branch.

## Foundational modules — sketches

### sops-nix wiring (`nixos-modules/services/sops/module.nix`)

```nix
imports = [ inputs.sops-nix.nixosModules.sops ];
config = mkIf cfg.enable {
  sops.defaultSopsFile = ../../../secrets/${config.networking.hostName}.yaml;
  sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];
  sops.age.keyFile     = "/var/lib/sops-nix/key.txt";
};
```

Add `sops-nix` flake input. Create `secrets/scheelite.yaml` (sops-encrypted) and
`secrets/.sops.yaml` (recipient config: scheelite host key + user age key).

Initial secrets needed (full list grew with declarative-config layer):

- `kanidm/admin`, `kanidm/idm-admin`
- `kanidm/oauth2-<service>` client secrets
- `oauth2-proxy/env`
- `<svc>/api-key` for each \*arr (sonarr, sonarr-anime, radarr, whisparr, prowlarr) — pre-generated UUIDs
- `<svc>/postgres-password` for each \*arr
- `qbittorrent/password` (plaintext; PBKDF2-hashed at preStart)
- `jellyfin/admin-password` (plaintext; consumed by /Startup/User and the Seerr bootstrap)
- `jellyseerr/admin-password` (placeholder for future direct-login flows)
- `nextcloud/admin-password`, `nextcloud/db-password`
- `immich/db-password`
- `paperless/admin-password`, `paperless/db-password`

### Caddy (`nixos-modules/services/caddy/module.nix`)

Enables `services.caddy`, opens 80/443 firewall, accepts vhost registrations from
other modules. Each service registers its own LAN vhost; Caddy uses internal CA
for local TLS. External-access modules will later add public vhosts on the same
Caddy.

### AdGuard Home (`nixos-modules/services/adguard/module.nix`)

```nix
services.adguardhome = {
  enable = true;
  mutableSettings = false;
  openFirewall = true;
  settings.dns = {
    bind_hosts = [ "0.0.0.0" ];
    upstream_dns = [ "https://1.1.1.1/dns-query" "https://9.9.9.9/dns-query" ];
    rewrites = [
      { domain = "*.scheelite.lan"; answer = cfg.lanIp; }
      { domain = "scheelite.lan";   answer = cfg.lanIp; }
    ];
  };
};
```

One-time user action: set router DHCP DNS to `(scheelite IP, 1.1.1.1)`.

### Per-service postgres helper (`nixos-modules/services/postgres/module.nix`)

Provides `theonecfg.services.postgres.instances.<name>` as `attrsOf submodule`.
Each entry produces a `containers."postgres-<name>"` with its own NixOS, its
own `services.postgresql` singleton, version-pinned, port-isolated:

```nix
postgres.instances.nextcloud = {
  version = "16";
  port = 5433;
  databases = [ "nextcloud" ];
  extensions = [];
};
```

The container bind-mounts `/persist/postgres/<name>` (its own ZFS dataset
with recordsize=8K) to its `/var/lib/postgresql/<version>`. Subnet derived
from port (`10.233.<port-5432>.0/24`). Host-side directory pre-created by
`systemd.tmpfiles.rules` with `config.ids.uids.postgres` ownership.

Service modules reference postgres via env vars (`<APP>__POSTGRES__HOST=127.0.0.1`,
`<APP>__POSTGRES__PORT=<port>`, etc.).

### Kanidm (`nixos-modules/services/kanidm/module.nix`)

```nix
services.kanidm = {
  enableServer = true;
  serverSettings = {
    domain = "id.scheelite.lan";
    origin = "https://id.scheelite.lan";
    bindaddress = "127.0.0.1:8443";
    ldapbindaddress = "127.0.0.1:6636";
    tls_chain = "/var/lib/kanidm/cert.pem";
    tls_key   = "/var/lib/kanidm/key.pem";
  };
  enableClient = true;
  clientSettings.uri = "https://id.scheelite.lan";
  provision = {
    enable = true;
    adminPasswordFile    = config.sops.secrets."kanidm/admin".path;
    idmAdminPasswordFile = config.sops.secrets."kanidm/idm-admin".path;
    groups."homelab-users".members = [ "djacu" ];
    persons.djacu = { /* … */ };
  };
};
```

### oauth2-proxy

Forward-auth for non-OIDC services. Emits a Caddyfile snippet
`(forward_auth_kanidm)` that per-service vhosts import.

## Declarative \*arr / Jellyfin / qBittorrent config

Full design: `scheelite-declarative-arr.md`. Summary:

**Layer 1 — Upstream `services.<name>` modules** (port, dataDir, package, user).

**Layer 2 — Env-var injection from sops.** \*arr stack supports
`<APP>__<SECTION>__<KEY>` env vars natively (.NET binding). Upstream
NixOS modules expose `services.<svc>.environmentFiles` and
`services.<svc>.settings`. We feed the API key + postgres password through
a sops template (`sops.templates."<svc>.env"`); non-secret server/auth/postgres
config goes through `services.<svc>.settings`.

**Layer 3 — Recyclarr** wraps `services.recyclarr` (in nixpkgs), pulls TRaSH
templates daily for Sonarr/Radarr quality profiles + custom formats.

**Layer 4 — Custom REST one-shots.** Helper library
`library/declarative-arr.nix` exports:

| Helper | Purpose |
|---|---|
| `mkSecureCurl` | curl wrapped with X-Api-Key from a sops file |
| `waitForApiScript` | bash snippet to wait for an HTTP endpoint |
| `mkArrApiPushService` | generic \*arr endpoint reconciler (GET → diff → POST/PUT/DELETE) |
| `mkJellyfinBootstrap` | runs `/Startup/{Configuration,User,RemoteAccess,Complete}` |
| `mkJellyfinLibrarySync` | reconciles `/Library/VirtualFolders` |
| `mkQbtPushService` | qBittorrent preferences + categories via REST |
| `qbtPasswordHashScript` | PBKDF2-hashes a sops plaintext into qBittorrent.conf |

Shared option types in `library/arr-types.nix` (`rootFolderType`, `indexerType`,
`applicationType`, `downloadClientType`, `delayProfileType`,
`jellyfinLibraryType`).

**Auto-derivation between modules:**

- Prowlarr's `applications` field auto-links to enabled \*arr modules
  (sonarr, sonarr-anime, radarr, whisparr).
- qBittorrent categories auto-derive a category per enabled \*arr.
- Jellyfin libraries auto-derive (sonarr → TV, sonarr-anime → Anime,
  radarr → Movies, pinchflat → YouTube).
- Jellyseerr connections auto-register all enabled \*arr instances after
  logging in via Jellyfin.

## Per-service module notes

| Service | Upstream | OIDC | Public-vhost candidate |
|---|---|---|---|
| Jellyfin | `services.jellyfin` | via SSO plugin (third-party but mature) | yes (later) |
| qBittorrent | `services.qbittorrent` | no — forward-auth + localhost bypass | no |
| Sonarr | `services.sonarr` | no — forward-auth | no |
| Sonarr-anime | manual systemd unit (services.sonarr is singleton) | no — forward-auth | no |
| Radarr | `services.radarr` | no — forward-auth | no |
| Whisparr | `services.whisparr` | no — forward-auth | no |
| Prowlarr | `services.prowlarr` | no — forward-auth | no |
| Pinchflat | `services.pinchflat` | no — forward-auth | no |
| Recyclarr | `services.recyclarr` | n/a (background sync) | no |
| Jellyseerr | `services.seerr` (renamed from jellyseerr in 26.05) | via Jellyfin OAuth | yes (later) |
| Nextcloud | `services.nextcloud` (with `user_oidc` app) | native | yes (later) |
| Immich | `services.immich` (24.11+) | native | yes (later) |
| Paperless-ngx | `services.paperless` (django-allauth OIDC) | native | yes (later) |

State paths (canonical):

- Jellyfin: `/tank0/services/jellyfin`, cache on `/tank0/services/jellyfin-cache`
- qBittorrent: `/tank0/services/qbittorrent`, downloads `/tank0/downloads`
- \*arr: `/tank0/services/{sonarr,sonarr-anime,radarr,whisparr,prowlarr}`
- Pinchflat: archives to `/tank0/media/youtube`
- Nextcloud: `/tank0/services/nextcloud`
- Immich: library on `/tank0/media/photos` (renamed from `/tank0/images/immich`)
- Paperless: `/tank0/services/paperless/{,media,consume}`

### tmpfiles vs. RequiresMountsFor — what's in our modules vs. upstream

Audited per-module to avoid duplicating what upstream NixOS modules already do:

| Module | Upstream creates dataDir? | Upstream `RequiresMountsFor`? | Our tmpfiles | Our `RequiresMountsFor` |
|---|---|---|---|---|
| jellyfin | yes (dataDir, configDir, logDir, cacheDir) | yes — but only configDir/logDir/cacheDir, not dataDir | none | dataDir + each library's path |
| sonarr | only when default; not when overridden | yes (cfg.dataDir) | dataDir | each rootFolder's path |
| sonarr-anime | n/a (we own the systemd unit) | n/a | dataDir | dataDir + each rootFolder's path |
| radarr | yes | yes | none | each rootFolder's path |
| whisparr | yes | no | none | dataDir + each rootFolder's path |
| qbittorrent | partial (creates qBittorrent subdirs only) | no | profileDir + downloadsDir + each category | profileDir + downloadsDir |
| pinchflat | only `/var/lib/pinchflat` (StateDirectory) | no | mediaDir | mediaDir |
| immich | yes (mediaLocation via tmpfiles) | no | none | mediaLocation (on `immich-server` AND `immich-machine-learning` — both run in parallel) |
| paperless | yes | yes (`= ReadWritePaths` on the leader) | none | none |
| nextcloud | yes (auto-creates dataDir parent via subdirs) | no | none | dataDir on `nextcloud-setup` (the leader) |
| loki | no | no | dataDir | dataDir |

## Monitoring stack — sketches

- **Prometheus** (`services.prometheus`): scrapes node_exporter, zfs_exporter,
  Scrutiny, service exporters where available.
  TSDB on `/tank0/services/prometheus`. ~1 GB/month at 15s scrape.
- **Grafana** (`services.grafana`): pre-provisioned datasources (Prometheus,
  Loki) + dashboards. State on `/tank0/services/grafana`. OIDC against Kanidm.
- **Loki** (`services.loki`): filesystem store on `/tank0/services/loki`.
  Default 30-day retention.
- **Grafana Alloy** (`services.alloy`): replaces promtail (which was removed in
  NixOS 26.05). Reads journald and ships to Loki. Config in River syntax at
  `/etc/alloy/config.alloy`.
- **Scrutiny** (`services.scrutiny`): SMART monitoring + web UI. Behind oauth2-proxy.
- **node_exporter, zfs_exporter** (`services.prometheus.exporters.{node,zfs}`).

LAN-only. Grafana is the most likely to want public access later — opt-in
via a `publicDomain` option once external access is decided.

## Scheelite wiring (`nixos-configurations/scheelite/default.nix`)

The full wiring block is committed with all enables set to `false`. Real
deployment fills in:

```nix
theonecfg.services = {
  sops.enable = true;
  caddy.enable = true;
  adguard = { enable = true; lanIp = "192.168.x.y"; };
  kanidm.enable = true;
  oauth2-proxy.enable = true;

  jellyfin = {
    enable = true;
    serverName = "scheelite";
    adminUser = "djacu";
  };
  qbittorrent.enable = true;
  sonarr = {
    enable = true;
    rootFolders = [ { path = "/tank0/media/tv"; } ];
  };
  sonarr-anime = {
    enable = true;
    rootFolders = [ { path = "/tank0/media/anime"; } ];
  };
  radarr = {
    enable = true;
    rootFolders = [ { path = "/tank0/media/movies"; } ];
  };
  whisparr = {
    enable = true;
    rootFolders = [ { path = "/tank0/media/adult"; } ];
  };
  prowlarr = {
    enable = true;
    indexers = [ /* per-indexer config from sops */ ];
  };
  pinchflat.enable = true;
  recyclarr = {
    enable = true;
    sonarrQuality = "4K";
    radarrQuality = "4K";
  };
  jellyseerr.enable = true;

  nextcloud.enable = true;
  immich.enable = true;
  paperless.enable = true;

  monitoring.prometheus.enable = true;
  monitoring.grafana.enable    = true;
  monitoring.loki.enable       = true;
  monitoring.alloy.enable      = true;
  monitoring.scrutiny.enable   = true;
  monitoring.node-exporter.enable = true;
  monitoring.zfs-exporter.enable  = true;
};
```

The `192.168.x.y` placeholder must be resolved to scheelite's actual LAN IP.

## Phased rollout

Each phase ends with a clean `nixos-rebuild build .#scheelite`.

1. **Phase 0 — Repo bootstrap** *(done at module-level).* `sops-nix` flake input,
   `nixos-modules/services/module.nix`, `secrets/.sops.yaml` placeholder.
   *Deployment prerequisites*: generate user age key, derive scheelite host
   age key, populate `secrets/.sops.yaml` and `secrets/scheelite.yaml`,
   apply disko via `nixos-anywhere`.
   *Verify*: `nix flake check` clean; sops decrypts; ZFS layout matches `disko.nix`.

1. **Phase 1 — Foundation modules.** Enable `sops`, `caddy`, `adguard`,
   `postgres`. Configure router DHCP to advertise `(scheelite, 1.1.1.1)`.
   *Verify*: AdGuard resolves `*.scheelite.lan`; Caddy serves placeholder
   vhost; sops decrypts at boot; a postgres container spins up on demand.

1. **Phase 2 — Identity.** Enable `kanidm` and `oauth2-proxy`.
   *Verify*: log in to Kanidm portal; oauth2-proxy gates a test vhost.

1. **Phase 3 — Media stack.** Enable `jellyfin`, `qbittorrent`, the \*arr
   instances (including `sonarr-anime`), `prowlarr`, `pinchflat`, `recyclarr`,
   and `jellyseerr`. All declarative — no web-UI clicks.
   *Verify*:

   - GET `/api/v3/system/status` on each \*arr returns 200 with the configured
     API key.
   - GET `/api/v3/rootfolder` on each \*arr shows the configured path.
   - GET `/api/v1/applications` on Prowlarr shows all enabled \*arr instances.
   - Jellyfin: `IsStartupWizardCompleted == true`; `/Library/VirtualFolders`
     shows TV / Anime / Movies / YouTube.
   - qBittorrent: localhost bypass works; `/api/v2/torrents/categories` lists
     each \*arr category.
   - Recyclarr daily timer runs and pushes TRaSH 4K profiles.
   - Jellyseerr `/api/v1/settings/public.initialized == true`; Sonarr / Radarr
     connections active.
   - End-to-end: add a TV show in Sonarr → Prowlarr finds release → qBittorrent
     downloads → Sonarr imports to `/tank0/media/tv` → Jellyfin auto-discovers.

1. **Phase 4 — Apps with DBs.** Nextcloud, Paperless, Immich. Native OIDC
   against Kanidm.
   *Verify*: each app reachable, Kanidm SSO works.

1. **Phase 5 — Monitoring.** Prometheus, Grafana, Loki, Alloy, Scrutiny,
   exporters.
   *Verify*: Prometheus targets all green; Grafana dashboards live; Alloy
   ships journal to Loki.

1. **Phase 6 — Backups.** **OUT OF SCOPE.** See `scheelite-backup-options.md`.

1. **Phase 7 — External access.** **OUT OF SCOPE.** See
   `scheelite-external-access-options.md`.

## Critical files

To create:

- `nixos-modules/services/module.nix` (auto-import)
- `nixos-modules/services/<name>/module.nix` for each module listed above,
  including `sonarr-anime`, `recyclarr`, `jellyseerr`
- `nixos-modules/services/monitoring/module.nix` (auto-import for the subdir)
- `library/declarative-arr.nix` — REST one-shot helpers
- `library/arr-types.nix` — shared option types
- `nixos-configurations/scheelite/disko.nix` — declarative pool + dataset config
- `secrets/.sops.yaml` (recipients)
- `secrets/scheelite.yaml` (sops-encrypted)

To modify:

- `flake.nix` — add `sops-nix` flake input
- `nixos-modules/default.nix` — import `inputs.sops-nix.nixosModules.sops`
- `library/default.nix` — re-export `declarative` and `arrTypes`
- `nixos-configurations/scheelite/impermanence.nix` — add new persistence directories
- `nixos-configurations/scheelite/default.nix` — enable `theonecfg.services.*`
  block (currently committed with all enables = `false`)
- `nixos-configurations/scheelite/hardware.nix` — to be cleaned up after
  the disko reinstall (drop the `fileSystems` and `swapDevices` entries
  that disko emits)

## Reused functions / patterns

- `library/default.nix` `getDirectoryNames` and `joinParentToPaths` —
  for module auto-import boilerplate (mirror `home-modules/services/module.nix:19-25`).
- `home-modules/programs/fish/module.nix:1-29` — module skeleton template.
- `nixos-modules/profiles/server/module.nix:1-34` — option/`mkIf cfg.enable` pattern.
- `nixos-configurations/scheelite/impermanence.nix` — extend the existing persistence
  block; don't add a parallel one.
- `config.ids.uids.<name>` and `config.ids.gids.<name>` — for stable system uids/gids
  in tmpfiles ownership.
- `theonecfg.library.declarative pkgs` — REST one-shot helpers.
- `theonecfg.library.arrTypes` — shared option types (rootFolderType etc.).

## Verification

Per phase (each module):

- `nix fmt` — passes treefmt.
- `nix flake check` — parses, type-checks, formatter-check (test-vm error
  is pre-existing and unrelated).
- `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel` —
  closes without error.
- After `switch`: `systemctl status <service>` for each new unit;
  `journalctl -u <service> -n 100` for clean startup.

End-to-end (declarative-config-specific):

- All `<svc>-bootstrap`, `<svc>-rootfolders`, `<svc>-applications`,
  `<svc>-libraries`, `<svc>-config`, `qbittorrent-config`,
  `jellyfin-bootstrap`, `jellyfin-libraries`, `jellyseerr-bootstrap`
  systemd units exit cleanly with `Result: success`.
- `journalctl -b 0 -u '*-bootstrap.service' -u '*-rootfolders.service' -u '*-applications.service' -u '*-libraries.service'` shows clean
  activations on every rebuild.
- Destroy `/tank0/services/<svc>` for any service, `nixos-rebuild switch`,
  watch the service come back up to declared state with no manual
  intervention.

## Deferred / out-of-scope this iteration

- **Backups**: see `scheelite-backup-options.md`.
- **Vaultwarden**: stand up only after the backup design lands and an off-site
  restore is verified end-to-end.
- **External access**: see `scheelite-external-access-options.md`.
- **Bazarr / Lidarr / Readarr / Audiobookshelf / Calibre-Web**: same pattern
  as the existing \*arr modules; future-service media datasets are pre-created
  in disko (`tank0/media/{music,audiobooks,books}`).
- **Hardware encoding for Jellyfin**: depends on whether the iGPU is exposed;
  the AMD Ryzen 7950X has Radeon graphics — revisit if 4K transcode becomes
  necessary.
- **Public Grafana/Nextcloud/Jellyfin/Immich/Jellyseerr vhosts**: gated on
  the external-access decision.
- **Tailscale, Headscale, Nebula, Cloudflare Tunnel installations**: also
  gated on the external-access decision.
- **Recyclarr for Whisparr**: Recyclarr doesn't support Whisparr. Whisparr
  uses Sonarr-style quality profiles; we'd write a small handcrafted set
  of custom formats in Nix later if the user cares.
- **Custom Jellyfin branding (logo, CSS)** and **plugin install** — helpers
  designed but not enabled this round.
- **SMTP relay for service notifications**: kanidm, jellyseerr, jellyfin,
  the *arr stack, nextcloud, and paperless all have email metadata fields
  populated from `theonecfg.knownUsers` but no SMTP transport, so nothing
  actually delivers. When notifications are wanted, add a
  `theonecfg.services.smtp-relay` module (msmtp/postfix relay listening
  on 127.0.0.1:25) backed by a transactional service (Mailgun, Resend,
  AWS SES) or Gmail app password, with credentials in sops. Each service
  points at `localhost:25`, centralizing SMTP config in one place.
- **Jellyseerr per-arr root folder override**: jellyseerr currently picks
  `lib.head <arrCfg>.rootFolders` per *arr to populate its connection
  config (Seerr's API takes a single root folder per *arr, but our *arr
  modules use a list). Works for the typical single-root case; if a user
  wants Seerr to send to a non-first root folder in a multi-root *arr,
  expose `jellyseerr.<arr>RootFolder` overrides defaulting to head-of-list.
