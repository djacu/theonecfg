# Stash + Stasharr Portal integration on scheelite

## Context

Adult-content acquisition on scheelite runs through Whisparr → `/tank0/media/adult`.
Whisparr's filename-based parser fails reliably on real-world adult content
(non-mainstream releases, mega-packs, repacks with cryptic filenames). The
proximate trigger was a downloaded mega-pack Whisparr couldn't break into
scenes; manual web-searching the filename was the only way to identify each
file.

Two upstream tools fix this:

- **Stash** (`stashapp/stash`) — Go + SQLite media organizer. Identifies
  scenes via PHash (perceptual hashing) against StashDB, ignoring filenames
  entirely. **`pkgs.stash` and `services.stash` already exist in nixpkgs
  unstable** (verified by reading
  `nixos/modules/services/web-apps/stash.nix` end-to-end:
  `services.stash.settings.stash_boxes` configures StashDB connections,
  `services.stash.scrapers/plugins` accept list-of-package).
- **Stasharr Portal** (`enymawse/stasharr-portal`, GPL-3.0) — NestJS 11 +
  Angular + Prisma 7 + Postgres self-hosted "Overseerr-for-adult-content".
  Browse StashDB/FansDB → request to Whisparr → check Stash for local
  availability. **No nixpkgs presence**; needs to be packaged.

End state: same Caddy + oauth2-proxy + sops + tank0 layout the rest of the
homelab already follows. Stash sits next to Whisparr (shared
`/tank0/media/adult` root); Stasharr Portal closes the loop the way
Jellyseerr does for the SFW stack.

### What this work does and does not solve

- **In scope:** PHash-based identification of adult scenes against StashDB
  (and optionally FansDB). Browse-and-request UI for adult content.
- **Out of scope — file renaming:** Stash by default tags scenes in its
  own SQLite DB *without* renaming files on disk. Stash *can* rename via
  `Tasks → Migrate / Rename Scenes` with configurable templates, but
  that's an opt-in manual workflow, not automatic on import.
- **Out of scope — Jellyfin/SFW organization:** Stash is adult-only
  (StashDB is an adult metadata catalog). Mainstream library quality
  issues (Jellyfin episode/movie identification) are a separate concern
  driven by Sonarr/Radarr/Sonarr-anime rename templates, not anything in
  this plan.

## Phases

### Phase 0 — Stash secrets in sops

User has a StashDB account and API token in hand. Three new keys needed
in `secrets/scheelite.yaml`:

- `stashdb/api-key` — the StashDB API token
- `stash/jwt-secret` — random; signs Stash session JWTs
- `stash/session-store-key` — random; encrypts Stash's session store

JWT and session-store keys can be generated locally with
`openssl rand -base64 48`. Both are required mkOptions on
`services.stash` (no defaults upstream); the module fails to evaluate
without them.

### Phase 1 — `theonecfg.services.stash`

Thin wrapper around upstream `services.stash`, mirroring the patterns in
`nixos-modules/services/whisparr/module.nix:1-230` (sops, Caddy,
RequiresMountsFor, media-group membership, ExecStartPre placeholder splice).

**New file:** `nixos-modules/services/stash/module.nix`

**Module options:**

```nix
theonecfg.services.stash = {
  enable      = mkEnableOption "Stash media organizer";
  domain      = default "stash.${config.theonecfg.networking.lanDomain}";
  port        = default 9999;
  dataDir     = default "/var/lib/stash";
  stashes     = listOf submodule { path = str; excludevideo, excludeimage = bool; }
                  default = [ ];   # populated in scheelite default.nix
                  # Field names match upstream stashType in
                  # nixpkgs/nixos/modules/services/web-apps/stash.nix:23-39
                  # (lowercase, no separator).
  stashBoxes  = listOf submodule { name = str; endpoint = str; apiKeyFile = path; }
                  default = [ ];   # populated in scheelite default.nix
};
```

**Wiring inside `config = mkIf cfg.enable (mkMerge [...])`:**

1. **Upstream service:**
   ```nix
   services.stash = {
     enable = true;
     dataDir = cfg.dataDir;
     user = "stash";
     group = "media";                 # cross-service shared media access
     mutableSettings = true;          # render config.yml once at first run;
                                      # Stash UI changes persist. With this
                                      # set true, declarative is for the
                                      # bootstrap shape (stash_boxes, libs);
                                      # day-to-day Settings live in the UI.
     jwtSecretKeyFile     = config.sops.secrets."stash/jwt-secret".path;
     sessionStoreKeyFile  = config.sops.secrets."stash/session-store-key".path;
     settings = {
       host = "127.0.0.1";
       port = cfg.port;
       stash = map (s: { inherit (s) path excludevideo excludeimage; }) cfg.stashes;
       # stash_boxes is rendered with placeholders; spliced post-startup.
       stash_boxes = map (b: {
         inherit (b) name endpoint;
         apikey = "@APIKEY_${b.name}@";
       }) cfg.stashBoxes;
     };
   };
   ```

2. **API-key splice via ExecStartPre** (matches whisparr-config-sync at
   `whisparr/module.nix:49-80`): a `writeShellApplication` that reads each
   `stashBoxes[*].apiKeyFile` and replaces the matching `@APIKEY_<name>@`
   placeholder in `${cfg.dataDir}/config.yml`. Wired with
   `lib.mkAfter`:
   ```nix
   systemd.services.stash.serviceConfig.ExecStartPre = lib.mkAfter [
     "+${stashApikeySplice}/bin/stash-apikey-splice"
   ];
   ```
   The `+` prefix makes it run as root (the upstream ExecStartPre creates
   `${dataDir}/config.yml` owned by `stash:media` mode 0644-ish; root can
   edit either way). With `mutableSettings = true`, the upstream
   ExecStartPre only writes `config.yml` once (at first run); subsequent
   restarts skip it. Our splice runs every restart anyway — but is a no-op
   if the placeholder is already replaced (idempotent via grep guard).

   **Idempotency:** the splice greps for `@APIKEY_*@` markers; if absent
   (Stash UI has rotated the apikey, say), it does nothing.

3. **Filesystem & user:**
   ```nix
   users.users.stash.extraGroups = [ "media" ];

   systemd.services.stash.unitConfig.RequiresMountsFor = map (s: s.path) cfg.stashes;

   # NOTE: NO tmpfiles rule for /tank0/media/adult here — Whisparr already
   # declares `d /tank0/media/adult 2775 whisparr media - -`. A second `d`
   # rule with different owner causes ownership to flip on each boot
   # (last-rule-wins). Stash's media-group membership + sgid=2775 + Whisparr's
   # writes inheriting group=media is enough for cross-service read access.
   ```

4. **Caddy (only if `theonecfg.services.caddy.enable`):**
   ```nix
   services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
     import acme_resolvers
     import forward_auth_kanidm
     reverse_proxy 127.0.0.1:${toString cfg.port}
   '';
   ```

5. **Sops:**
   ```nix
   sops.secrets = {
     "stash/jwt-secret".owner = "stash";
     "stash/session-store-key".owner = "stash";
   };
   # stashdb/api-key is owned by stash but declared in scheelite/default.nix
   # alongside the per-host stashBoxes list (single source of truth for
   # which boxes exist on this host).
   ```

6. **No Postgres** — Stash uses SQLite, written under `dataDir`.

7. **Caveat — upstream `BindReadOnlyPaths`:** the nixpkgs module sets
   `BindReadOnlyPaths = map (s: s.path) cfg.settings.stash`. Stash's view
   of library paths is read-only inside its mount namespace. That's
   correct semantics (Stash doesn't write to library files; only reads
   for hashing/scanning) but worth noting if you ever want Stash to
   rename files on disk via Tasks → Migrate — that operation needs
   filesystem write access. If/when that becomes a workflow, drop the
   read-only bind via `systemd.services.stash.serviceConfig.BindReadOnlyPaths
   = lib.mkForce [ ];` and add the paths under `BindPaths` (read-write)
   instead. Out of scope for v1.

**Scheelite wiring** (`nixos-configurations/scheelite/default.nix`):

```nix
theonecfg.services.stash = {
  enable = true;
  dataDir = "${tankServicesDir}/stash";
  stashes = [
    { path = "${tankMediaDir}/adult"; }   # shared with Whisparr
  ];
  stashBoxes = [
    {
      name = "StashDB";
      endpoint = "https://stashdb.org/graphql";
      apiKeyFile = config.sops.secrets."stashdb/api-key".path;
    }
  ];
};

sops.secrets."stashdb/api-key".owner = "stash";
```

**ZFS dataset** (`nixos-configurations/scheelite/disko.nix`):

```nix
"tank0/services/stash" = {
  type = "zfs_fs";
  mountpoint = "/tank0/services/stash";
  options.mountpoint = "/tank0/services/stash";
  # Stash stores SQLite + cache + blobs here. SQLite benefits from a
  # smaller recordsize than the tank0/services default; the postgres
  # datasets use 16K, same logic applies.
  options.recordsize = "16K";
  options.atime = "off";
};
```

**Verification:**

- `systemctl status stash` running.
- `https://stash.scheelite.dev` reaches Stash UI through Caddy + kanidm
  forward_auth (oauth2-proxy on `127.0.0.1:4180`).
- Stash UI → Settings → Metadata Providers shows StashDB connection live
  (the placeholder splice replaced `@APIKEY_StashDB@` with the real
  token).
- Stash UI → Settings → Library lists `/tank0/media/adult`; a scan
  succeeds and produces fingerprints.
- On the mega-pack: run `Tasks → Identify` against StashDB; confirm
  PHash-based matches resolve scenes that filename parsing couldn't.
  (PHash hits depend on StashDB cataloging the content; obscure releases
  may still miss until someone submits fingerprints upstream.)

### Phase 2 — `pkgs.stasharr-portal` (Nix package)

Native nix package for the upstream NestJS+Angular+Prisma monorepo.
License GPL-3.0, no blockers.

**Stack confirmed via clone of `enymawse/stasharr-portal` to `/tmp/investigate`:**

- Node.js 22 (`.nvmrc:1`)
- pnpm 10.32.0 workspace; `apps/sp-api` (NestJS 11) + `apps/sp-web`
  (Angular 21)
- Prisma `^7.4.2` per `package.json`; lockfile pins 7.4.2 exactly
- argon2 native module → needs OpenSSL + node-gyp toolchain
- Single Node process serves both API and SPA (verified
  `apps/sp-api/src/main.ts:22-44` — `useStaticAssets` for
  `apps/sp-web/dist/sp-web/browser`, falls through to `index.html` for
  SPA routes)
- Bootstrap entrypoint is `infrastructure/docker/start-app.sh` (handles
  session-secret persistence + DATABASE_URL derivation + retry-loop
  Prisma migrations before exec'ing node). We reuse this directly.
- Latest tag: `v0.1.0`. HEAD has two newer commits but no tag yet.
  Pin to v0.1.0 for reproducibility.

**New file:** `package-sets/top-level/stasharr-portal/default.nix`

(NOT `pkgs/stasharr-portal/` — this repo's custom packages live at
`package-sets/top-level/<name>/default.nix` and are auto-imported into
the overlay via `packagesFromDirectoryRecursive` in
`overlays/default.nix:48-54`.)

**Derivation shape:**

```nix
{ stdenv, lib, fetchFromGitHub, nodejs_22, pnpm, prisma-engines_7,
  openssl, python3, makeWrapper, ... }:

stdenv.mkDerivation (finalAttrs: {
  pname = "stasharr-portal";
  version = "0.1.0";
  src = fetchFromGitHub {
    owner = "enymawse"; repo = "stasharr-portal";
    tag = "v${finalAttrs.version}";
    hash = lib.fakeHash;  # filled on first build
  };

  pnpmDeps = pnpm.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = lib.fakeHash;  # filled on first build
  };

  nativeBuildInputs = [
    nodejs_22 pnpm.configHook prisma-engines_7
    python3 makeWrapper
  ];
  buildInputs = [ openssl ];

  env = {
    # prisma-engines_7 in nixpkgs ships ONLY the schema-engine
    # (cargoBuildFlags = ["-p" "schema-engine-cli"]). Setting other
    # PRISMA_*_BINARY env vars points at non-existent paths.
    # Stasharr uses Prisma 7's @prisma/adapter-pg driver-adapter
    # (apps/sp-api/src/prisma/prisma.service.ts:5,17), so the runtime
    # query engine is satisfied by the JS adapter — schema-engine
    # is only needed for `prisma migrate deploy` at startup.
    PRISMA_SCHEMA_ENGINE_BINARY = "${prisma-engines_7}/bin/schema-engine";

    # Block Angular CLI's first-run telemetry prompt during the build.
    NG_CLI_ANALYTICS = "ci";
  };

  buildPhase = ''
    runHook preBuild

    # `pnpm.configHook` runs `pnpm install --offline --ignore-scripts
    # --frozen-lockfile`, which skips argon2's postinstall native build.
    # Force the rebuild explicitly here so the runtime closure has the
    # compiled .node binary. argon2's build needs python3 + a C compiler
    # (stdenv default) + openssl headers, all in inputs already.
    pnpm rebuild argon2

    # Prisma 7 client generation; needs DATABASE_URL set even just to
    # generate (validated against Dockerfile:13-14).
    DATABASE_URL='postgresql://placeholder:placeholder@localhost:5432/placeholder' \
      ./node_modules/.bin/prisma generate --schema prisma/schema.prisma

    pnpm --filter sp-api build
    pnpm --filter sp-web build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -d $out/share/stasharr-portal
    install -d $out/share/stasharr-portal/apps/sp-api
    install -d $out/share/stasharr-portal/apps/sp-web

    # Match the Dockerfile's runtime-image layout (Dockerfile:30-39).
    # `cp -r` preserves pnpm's symlink-farm node_modules layout (no -L).
    cp -r package.json prisma.config.ts node_modules prisma \
          $out/share/stasharr-portal/
    cp -r apps/sp-api/dist apps/sp-api/node_modules apps/sp-api/package.json \
          $out/share/stasharr-portal/apps/sp-api/
    cp -r apps/sp-web/dist $out/share/stasharr-portal/apps/sp-web/

    # Reuse upstream's bootstrap entrypoint. Patch the absolute /app/
    # paths (which assume Docker WORKDIR=/app) to relative; the systemd
    # unit will set WorkingDirectory accordingly.
    install -m 0755 infrastructure/docker/start-app.sh \
      $out/share/stasharr-portal/start-app.sh
    substituteInPlace $out/share/stasharr-portal/start-app.sh \
      --replace-fail '/app/' './'

    # Convenience entrypoint for the systemd unit.
    install -d $out/bin
    makeWrapper $out/share/stasharr-portal/start-app.sh \
      $out/bin/stasharr-portal

    runHook postInstall
  '';

  meta = with lib; {
    description = "Self-hosted media-acquisition orchestration console for Whisparr, enriched by StashDB metadata";
    homepage = "https://github.com/enymawse/stasharr-portal";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
    mainProgram = "stasharr-portal";
  };
})
```

**Catches & risks (real, expect iteration):**

- **Pnpm version drift, mostly handled** — lockfile says 10.32.0;
  nixpkgs ships `pnpm_10_29_2`. nixpkgs's `pnpm-config-hook` already
  runs `pnpm config set manage-package-manager-versions false` to
  bypass the corepack version check
  (`nixpkgs/pkgs/build-support/node/fetch-pnpm-deps/pnpm-config-hook.sh:21-24`).
  Risk: if the lockfile schema uses a feature only 10.32 understands,
  `--frozen-lockfile` will fail. Verify empirically.
- **argon2 native build** — handled by explicit `pnpm rebuild argon2`
  in the build phase (the offline install runs with `--ignore-scripts`,
  which skips argon2's postinstall).
- **Prisma version drift** — package.json declares `^7.4.2` (maintainers
  accept 7.x drift); lockfile pins 7.4.2 exactly. nixpkgs
  `prisma-engines_7` is at 7.8.0. Within the same major version, the
  schema-engine ↔ CLI protocol is generally backwards compatible.
  Verify by running `prisma migrate deploy` during Phase 3 deployment;
  if it errors with a Prisma protocol-mismatch message, fall back to
  the OCI image (see "Decision space deferred" below).
- **Project maturity** — Stasharr at v0.1.0; CONTRIBUTING.md already
  documents a one-off "repair runtime-health migration" workaround.
  Pin to exact tags; expect to re-vendor on each upgrade.

**Overlay wiring:** automatic. `overlays/default.nix:48-54` calls
`packagesFromDirectoryRecursive { directory = ../package-sets/top-level; }`
which exposes every top-level dir under `pkgs.<name>`. Adding
`package-sets/top-level/stasharr-portal/` is the only step.

### Phase 3 — `theonecfg.services.stasharr` (Stasharr Portal NixOS module)

Wraps the Phase-2 package + per-service Postgres + Caddy + sops.

**New file:** `nixos-modules/services/stasharr/module.nix`

**Module options:**

```nix
theonecfg.services.stasharr = {
  enable       = mkEnableOption "Stasharr Portal";
  domain       = default "stasharr.${config.theonecfg.networking.lanDomain}";
  port         = default 8084;       # Verified free across all repo modules.
                                     # Avoids 3000 (AdGuard), 8082 (homepage),
                                     # 8083 (scrutiny).
  host         = default "127.0.0.1";
  dataDir      = default "/var/lib/stasharr";   # session-secret persistence
  dbPort       = default 5441;       # Next free after Prowlarr's 5440.
  cookieSecure = default true;
};
```

**Wiring:**

1. **System user** (no `media` group needed — Stasharr talks to
   Stash/Whisparr via HTTP, not the filesystem; verified by reading
   `apps/sp-api/src/providers/{stash,whisparr,stashdb}/*.adapter.ts` —
   all interactions go through `fetch()` against configured `baseUrl`):
   ```nix
   users.users.stasharr = {
     isSystemUser = true;
     group = "stasharr";
     home = cfg.dataDir;
   };
   users.groups.stasharr = { };
   ```

2. **Postgres** via existing helper:
   ```nix
   theonecfg.services.postgres.instances.stasharr = {
     version = "16";
     port = cfg.dbPort;
     databases = [ "stasharr" ];
     owner = "stasharr";
   };
   ```

3. **systemd unit** — uses upstream `start-app.sh` as `ExecStart`. The
   script is the same code path the Dockerfile entrypoints to and
   handles, in order: session-secret persistence at
   `${APP_DATA_DIR}/session-secret`, `DATABASE_URL` derivation from
   `POSTGRES_*` env, retry-loop `prisma migrate deploy`, then
   `exec node apps/sp-api/dist/main.js`.

   ```nix
   systemd.tmpfiles.rules = [
     "d ${cfg.dataDir} 0700 stasharr stasharr - -"
   ];

   systemd.services.stasharr = {
     description = "Stasharr Portal";
     after = [ "network.target" "container@postgres-stasharr.service" ];
     requires = [ "container@postgres-stasharr.service" ];
     # Container unit names: theonecfg.services.postgres.instances.<name>
     # creates `containers."postgres-<name>"`, which NixOS realizes as
     # the templated unit `container@postgres-<name>.service`.
     wantedBy = [ "multi-user.target" ];
     path = with pkgs; [ openssl coreutils nodejs_22 ];
     environment = {
       NODE_ENV    = "production";
       HOST        = cfg.host;
       PORT        = toString cfg.port;
       POSTGRES_DB     = "stasharr";
       POSTGRES_USER   = "stasharr";
       DATABASE_HOST   = pgInstance.host;             # container veth IP
       DATABASE_MIGRATION_MAX_ATTEMPTS         = "30";
       DATABASE_MIGRATION_RETRY_DELAY_SECONDS  = "2";
       SESSION_COOKIE_SECURE = if cfg.cookieSecure then "true" else "false";
       APP_DATA_DIR    = cfg.dataDir;
       SESSION_SECRET_FILE = "${cfg.dataDir}/session-secret";
       STASHARR_VERSION    = pkgs.stasharr-portal.version;
     };
     serviceConfig = {
       User = "stasharr";
       Group = "stasharr";
       WorkingDirectory = "${pkgs.stasharr-portal}/share/stasharr-portal";
       EnvironmentFile = config.sops.templates."stasharr.env".path;
       ExecStart = "${pkgs.stasharr-portal}/bin/stasharr-portal";
       Restart = "on-failure";
       RestartSec = "5s";
     };
   };
   ```

4. **Sops:**
   ```nix
   sops.secrets."stasharr/postgres-password".owner = "stasharr";
   sops.templates."stasharr.env" = {
     content = ''
       POSTGRES_PASSWORD=${config.sops.placeholder."stasharr/postgres-password"}
     '';
     owner = "stasharr";
   };
   ```

5. **Caddy:**
   ```nix
   services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
     import acme_resolvers
     import forward_auth_kanidm
     reverse_proxy 127.0.0.1:${toString cfg.port}
   '';
   ```
   **UX note:** Stasharr has its own local-admin login (single-tenant;
   not OIDC-aware — confirmed in
   `apps/sp-api/src/auth/auth.service.ts` + `prisma/schema.prisma:17-27`
   `AdminUser` model). Behind Kanidm forward_auth that means double
   authentication (Kanidm gate, then Stasharr local-admin). Defense in
   depth fits the rest of the stack; drop `forward_auth_kanidm` from
   the vhost only if the double-login proves annoying after living with
   it.

**Scheelite wiring:**

```nix
theonecfg.services.stasharr = {
  enable = true;
  dataDir = "${tankServicesDir}/stasharr";
};

sops.secrets."stasharr/postgres-password".owner = "stasharr";
```

**ZFS datasets** (`nixos-configurations/scheelite/disko.nix`):

```nix
# tank0 service-state dataset
"tank0/services/stasharr" = {
  type = "zfs_fs";
  mountpoint = "/tank0/services/stasharr";
  options.mountpoint = "/tank0/services/stasharr";
};

# Per-instance postgres dataset (matches sibling pattern at
# disko.nix:243-313 — recordsize=16K + atime=off).
"safe/persist/postgres/stasharr" = {
  type = "zfs_fs";
  mountpoint = "/persist/postgres/stasharr";
  options = {
    mountpoint = "/persist/postgres/stasharr";
    recordsize = "16K";
    atime = "off";
  };
};
```

**Verification:**

- `systemctl status stasharr` running; `journalctl -u stasharr` shows
  `Loaded persisted session secret` (or `Generated and persisted ...`
  on first run) → `Applying Prisma migrations` → `Starting Stasharr`.
- `https://stasharr.scheelite.dev` reaches the Portal bootstrap screen
  through Caddy + kanidm forward_auth.
- Bootstrap creates the local admin account.
- In Settings, configure integrations using **loopback URLs** (server-side
  `fetch()` against `https://*.scheelite.dev` would hit Caddy +
  forward_auth and 401 with no Kanidm session):
  - Whisparr: `URL = http://127.0.0.1:6969`, API key from
    `secrets/scheelite.yaml` `whisparr/api-key`.
  - Stash: `URL = http://127.0.0.1:9999`, API key generated in
    Stash UI → Settings → Security.
  - StashDB (catalog provider): `URL = https://stashdb.org/graphql`,
    API key from your StashDB account profile.
- Browse a StashDB scene → click Request → confirm Whisparr received the
  entry (check Whisparr UI, or `curl -H 'X-Api-Key: ...'
  http://127.0.0.1:6969/api/v3/movie`).
- Local-availability badge correctly reflects scenes already in Stash.
- If the journal shows a Prisma protocol-mismatch error during
  `migrate deploy`, capture the exact message and fall back to the OCI
  contingency below.

### Phase 4 — Stasharr userscript (out of scope)

The userscript edition (`enymawse/stasharr` main branch) runs in your
browser via Tampermonkey/Violentmonkey. Not a NixOS-managed concern;
install if desired from upstream releases page after Phase 1 + 3 are
running. Configure with the same `https://whisparr.scheelite.dev` /
`https://stash.scheelite.dev` URLs (the script runs in the browser and
goes through Caddy as a normal authenticated user — loopback workaround
in Phase 3 only applies to server-side fetches).

## Critical files

**To create:**

- `nixos-modules/services/stash/module.nix` (Phase 1)
- `package-sets/top-level/stasharr-portal/default.nix` (Phase 2)
- `nixos-modules/services/stasharr/module.nix` (Phase 3)

**To modify:**

- `nixos-configurations/scheelite/default.nix` — enable both services + sops secret declarations
- `nixos-configurations/scheelite/disko.nix` — add `tank0/services/stash`,
  `tank0/services/stasharr`, `safe/persist/postgres/stasharr`
- `secrets/scheelite.yaml` — add `stashdb/api-key`,
  `stash/jwt-secret`, `stash/session-store-key`,
  `stasharr/postgres-password`

**To reference (read-only patterns to mirror):**

- `nixos-modules/services/whisparr/module.nix:1-230` — *arr module
  skeleton (sops, Caddy, RequiresMountsFor, ExecStartPre config-sync via
  `lib.mkAfter`)
- `nixos-modules/services/postgres/module.nix` — per-service postgres
  helper. Notable: `pgInstance.host` returns the container veth IP
  (10.233.<idx>.2 with idx = port - 5432); Stasharr's
  `DATABASE_HOST` reads from this. Container unit name:
  `container@postgres-<name>.service`.
- `nixos-modules/services/oauth2-proxy/module.nix:117-145` — definition
  of the `forward_auth_kanidm` Caddy snippet imported by per-service
  vhosts.
- `nixos-modules/services/caddy/module.nix:81-87` — definition of the
  `acme_resolvers` snippet (handles Porkbun DNS-01 ACME walk-up
  through public resolvers, bypassing local AdGuard).

## Decision space deferred

- **Recyclarr-style declarative Stasharr settings** — Stasharr exposes
  a REST API for catalog-provider/Whisparr/Stash configuration. A
  reconciliation one-shot (à la `library/declarative-arr.nix`'s
  `mkArrApiPushService`) is a Phase 5. For now, configuration via the
  Portal UI on first run is acceptable.
- **Auth simplification** — drop `forward_auth_kanidm` from the
  Stasharr vhost if double-login proves annoying. Decide after living
  with it.
- **OCI fallback for Phase 2** — if native Nix packaging hits a wall
  (most likely cause: Prisma 7.4.2 CLI ↔ 7.8.0 schema-engine protocol
  mismatch surfacing as a `migrate deploy` error), fall back to
  `virtualisation.oci-containers` running
  `ghcr.io/enymawse/stasharr-portal:v0.1.0` with the same env-var
  surface. Keeps Phases 1, 3, 4 untouched.
- **Stash file renaming** — Tasks → Migrate / Rename Scenes works only
  if upstream `BindReadOnlyPaths` is forced empty and library paths
  rebound read-write. Out of scope for v1; revisit if filename quality
  on the adult library becomes a problem.

## End-to-end verification

1. `nix flake check` passes.
2. `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel` succeeds.
3. Deploy via `nixos-rebuild --target-host scheelite --sudo --ask-sudo-password switch`.
4. **Stash:** UI reachable at `https://stash.scheelite.dev`; StashDB
   connection populated (placeholder splice replaced); `/tank0/media/adult`
   scanned; Identify-from-StashDB workflow resolves scenes from the test
   mega-pack via PHash matching that filename parsing alone could not.
5. **Stasharr Portal:** UI bootstraps cleanly; postgres migration runs;
   Whisparr + Stash integrations connect (loopback URLs); sample
   scene-request from a StashDB browse view reaches Whisparr.
6. Both `https://stash.scheelite.dev` and `https://stasharr.scheelite.dev`
   served behind Caddy + kanidm forward_auth with valid Let's Encrypt
   certs.

## Implementation tasks

### Pre-flight

- Branch: `rework-scheelite`. Each task ends in an atomic commit on this
  branch. No `Co-Authored-By:` trailers. No future-references in commit
  messages — describe what's true at that point in history.
- For every new `.nix` file: immediately run `git add -N <path>` after
  creation. Nix flakes ignore untracked files; `nix flake check` reports
  `option does not exist` on freshly-created modules until they're at
  least intent-tracked.
- `nix flake check` is the cheap evaluation gate (~10-30s).
  `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel`
  is the full build gate (1-5 min). Run flake check between most tasks;
  toplevel build before deploys.
- Datasets on the live system must exist before the rebuild that
  references them — see the disko investigation in the prior section.
  For each new dataset: SSH and `zfs create` first, then commit the
  declarative `disko.nix` update.
- The user runs every `nixos-rebuild --target-host` deploy themselves
  (interactive sudo password). Pre-deploy build verification is
  done from the workstation.

### Phase 0 — Stash secrets in sops

#### Task 0.1 — Add stashdb/stash keys to scheelite secrets

**Files:**

- Modify: `secrets/scheelite.yaml`

**Steps:**

- [ ] **Step 1: Generate the two random keys**

```bash
echo "stash/jwt-secret = $(openssl rand -base64 48)"
echo "stash/session-store-key = $(openssl rand -base64 48)"
```

Note both values; you'll paste them in the next step.

- [ ] **Step 2: Edit the encrypted secrets file**

```bash
cd /home/djacu/dev/djacu/theonecfg
sops secrets/scheelite.yaml
```

Add three entries under existing top-level keys (creating the keys if
absent):

```yaml
stashdb:
    api-key: <paste your StashDB API token>
stash:
    jwt-secret: <paste step-1 jwt-secret>
    session-store-key: <paste step-1 session-store-key>
```

Save and exit; sops re-encrypts.

- [ ] **Step 3: Verify decryption**

```bash
sops --decrypt secrets/scheelite.yaml | grep -E "stashdb:|stash:|jwt-secret|session-store-key|api-key" | head
```

Expected output: lines showing the three new entries in plaintext.

- [ ] **Step 4: Commit**

```bash
git add secrets/scheelite.yaml
git commit -m "secrets/scheelite: add stashdb api-key and stash session secrets"
```

### Phase 1 — `theonecfg.services.stash`

#### Task 1.1 — Stash module skeleton + core wiring

**Files:**

- Create: `nixos-modules/services/stash/module.nix`

**Steps:**

- [ ] **Step 1: Create the module file**

Write `nixos-modules/services/stash/module.nix` matching the design in
Phase 1 above (option block + `services.stash` config + sops secrets +
`users.users.stash.extraGroups` + Caddy vhost + RequiresMountsFor).
Include the `apikey = "@APIKEY_${b.name}@"` placeholder in the
`stash_boxes` mapping; the splice service comes in Task 1.2.

Skeleton that this task lands:

```nix
{ config, lib, pkgs, ... }:
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) bool listOf int str submodule;

  cfg = config.theonecfg.services.stash;

  stashType = submodule { options = {
    path = mkOption { type = str; };
    excludevideo = mkOption { type = bool; default = false; };
    excludeimage = mkOption { type = bool; default = false; };
  }; };
  stashBoxType = submodule { options = {
    name = mkOption { type = str; };
    endpoint = mkOption { type = str; };
    apiKeyFile = mkOption { type = str; };
  }; };
in
{
  options.theonecfg.services.stash = {
    enable = mkEnableOption "Stash media organizer";
    domain = mkOption { type = str; default = "stash.${config.theonecfg.networking.lanDomain}"; };
    port = mkOption { type = int; default = 9999; };
    dataDir = mkOption { type = str; default = "/var/lib/stash"; };
    stashes = mkOption { type = listOf stashType; default = [ ]; };
    stashBoxes = mkOption { type = listOf stashBoxType; default = [ ]; };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.stash = {
        enable = true;
        dataDir = cfg.dataDir;
        user = "stash";
        group = "media";
        mutableSettings = true;
        jwtSecretKeyFile     = config.sops.secrets."stash/jwt-secret".path;
        sessionStoreKeyFile  = config.sops.secrets."stash/session-store-key".path;
        settings = {
          host = "127.0.0.1";
          port = cfg.port;
          stash = map (s: { inherit (s) path excludevideo excludeimage; }) cfg.stashes;
          stash_boxes = map (b: {
            inherit (b) name endpoint;
            apikey = "@APIKEY_${b.name}@";
          }) cfg.stashBoxes;
        };
      };

      users.users.stash.extraGroups = [ "media" ];

      systemd.services.stash.unitConfig.RequiresMountsFor =
        map (s: s.path) cfg.stashes;

      sops.secrets = {
        "stash/jwt-secret".owner = "stash";
        "stash/session-store-key".owner = "stash";
      };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import acme_resolvers
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
```

- [ ] **Step 2: Track the new file with git**

```bash
git add -N nixos-modules/services/stash/module.nix
```

- [ ] **Step 3: Run flake check**

```bash
nix flake check
```

Expected: passes. The module is auto-imported via
`nixos-modules/services/module.nix` (per repo convention; see
`nixos-modules/services/whisparr/` etc. — no manual wiring needed).
Module isn't enabled on any host yet, so it just adds an option.

- [ ] **Step 4: Commit**

```bash
git add nixos-modules/services/stash/module.nix
git commit -m "nixos-modules/services/stash: new module — Stash media organizer"
```

#### Task 1.2 — Stash apikey splice ExecStartPre

**Files:**

- Modify: `nixos-modules/services/stash/module.nix`

**Steps:**

- [ ] **Step 1: Add the splice script**

In the module's `let` block, add:

```nix
stashApikeySplice = pkgs.writeShellApplication {
  name = "stash-apikey-splice";
  runtimeInputs = [ pkgs.coreutils pkgs.yq-go ];
  text = ''
    set -euo pipefail
    config="${cfg.dataDir}/config.yml"

    if [ ! -f "$config" ]; then
      echo "stash config.yml not found at $config" >&2
      exit 1
    fi

    ${lib.concatMapStringsSep "\n" (b: ''
      if [ -r "${b.apiKeyFile}" ]; then
        NEW_KEY="$(tr -d '\r\n' < "${b.apiKeyFile}")" \
          yq -i \
          '(.stash_boxes[] | select(.name == "${b.name}") | .apikey) = strenv(NEW_KEY)' \
          "$config"
      fi
    '') cfg.stashBoxes}

    chown stash:media "$config"
    chmod 0600 "$config"
  '';
};
```

`yq` is yaml-aware (handles arbitrary characters in API keys safely);
`select(.name == "X")` finds the right `stash_boxes[]` entry by name;
the substitution is idempotent (replacing a real key with itself is a
no-op).

- [ ] **Step 2: Wire ExecStartPre**

In the first `mkMerge` branch, after `users.users.stash.extraGroups`:

```nix
systemd.services.stash.serviceConfig.ExecStartPre = lib.mkAfter [
  "+${stashApikeySplice}/bin/stash-apikey-splice"
];
```

The `+` prefix runs as root (needed to chown after edit); `lib.mkAfter`
chains it after the upstream module's ExecStartPre that renders config.yml.

- [ ] **Step 3: Run flake check**

```bash
nix flake check
```

Expected: passes.

- [ ] **Step 4: Commit**

```bash
git commit -am "nixos-modules/services/stash: splice runtime apikey into stash_boxes"
```

#### Task 1.3 — Enable Stash on scheelite (declarative)

**Files:**

- Modify: `nixos-configurations/scheelite/default.nix`
- Modify: `nixos-configurations/scheelite/disko.nix`

**Steps:**

- [ ] **Step 1: Add the service block to scheelite/default.nix**

Inside the `theonecfg.services` attrset (alphabetically near `sonarr`,
or appended), add:

```nix
stash = {
  enable = true;
  dataDir = "${tankServicesDir}/stash";
  stashes = [
    { path = "${tankMediaDir}/adult"; }
  ];
  stashBoxes = [
    {
      name = "StashDB";
      endpoint = "https://stashdb.org/graphql";
      apiKeyFile = config.sops.secrets."stashdb/api-key".path;
    }
  ];
};
```

And outside the `theonecfg.services` attrset (next to other per-host
sops decls):

```nix
sops.secrets."stashdb/api-key".owner = "stash";
```

- [ ] **Step 2: Add the disko dataset**

In `nixos-configurations/scheelite/disko.nix`, inside
`scheelite-tank0.datasets`, add:

```nix
"tank0/services/stash" = {
  type = "zfs_fs";
  mountpoint = "/tank0/services/stash";
  options = {
    mountpoint = "/tank0/services/stash";
    recordsize = "16K";
    atime = "off";
  };
};
```

- [ ] **Step 3: Build the toplevel**

```bash
nix build .#nixosConfigurations.scheelite.config.system.build.toplevel
```

Expected: succeeds. The build doesn't check that ZFS datasets exist;
it just produces a system closure.

- [ ] **Step 4: Commit**

```bash
git add nixos-configurations/scheelite/default.nix nixos-configurations/scheelite/disko.nix
git commit -m "nixos-configurations/scheelite: enable Stash on /tank0/media/adult"
```

#### Task 1.4 — Create dataset on live scheelite + deploy + verify

**Operational task** (no commit).

**Steps:**

- [ ] **Step 1: SSH to scheelite and create the dataset**

```bash
ssh scheelite
sudo zfs create -o recordsize=16K -o atime=off scheelite-tank0/tank0/services/stash
zfs list -o name,mountpoint,recordsize,atime scheelite-tank0/tank0/services/stash
```

Expected: dataset listed with the right mountpoint/recordsize/atime.

- [ ] **Step 2: Deploy from the workstation**

```bash
nixos-rebuild --flake .#scheelite --target-host scheelite --sudo --ask-sudo-password switch
```

Expected: switch succeeds; new `tank0-services-stash.mount` and
`stash.service` units start.

- [ ] **Step 3: Verify Stash is running**

```bash
ssh scheelite "systemctl status stash --no-pager | head -20"
ssh scheelite "journalctl -u stash --since '5 minutes ago' --no-pager | tail -20"
```

Expected: `active (running)`; logs show stash listening on
`127.0.0.1:9999`. Look for any "stash-apikey-splice" output too.

- [ ] **Step 4: Verify Caddy reverse-proxy + kanidm**

In a browser: `https://stash.scheelite.dev`. Expected: kanidm forward
auth challenge, then the Stash UI.

- [ ] **Step 5: Verify StashDB connection**

In Stash UI → Settings → Metadata Providers. Expected: StashDB row
shows `https://stashdb.org/graphql` with the API key populated (the
splice replaced `@APIKEY_StashDB@` with the real token). Click "Test"
to confirm the key is accepted.

- [ ] **Step 6: Trigger an Identify-from-StashDB on the mega-pack**

In Stash UI → Tasks → Identify → select the mega-pack folder → run.
Expected: PHash-based matches against StashDB resolve scenes that
filename parsing alone misses.

### Phase 2 — `pkgs.stasharr-portal`

#### Task 2.1 — Stasharr-portal Nix derivation

**Files:**

- Create: `package-sets/top-level/stasharr-portal/default.nix`

**Steps:**

- [ ] **Step 1: Create the derivation file**

Write `package-sets/top-level/stasharr-portal/default.nix` with the
shape from the Phase 2 design above. Set `hash = lib.fakeHash;` for
both `src` and `pnpmDeps`. Include `pnpm rebuild argon2` in
buildPhase, the start-app.sh `/app/` → `./` substitution in
installPhase, and the `mainProgram = "stasharr-portal"` meta entry.

- [ ] **Step 2: Track the new file**

```bash
git add -N package-sets/top-level/stasharr-portal/default.nix
```

- [ ] **Step 3: Build and capture src hash**

```bash
nix build .#stasharr-portal 2>&1 | tee /tmp/build.log
```

Expected: failure with
`hash mismatch in fixed-output derivation '...stasharr-portal-...src.drv'`
followed by `specified: ...AAAAAAAA...` and `got: sha256-<actualhash>`.

Copy the `got: sha256-...` value into `src.hash` in the derivation
file (replacing `lib.fakeHash`).

- [ ] **Step 4: Build and capture pnpmDeps hash**

```bash
nix build .#stasharr-portal 2>&1 | tee /tmp/build.log
```

Expected: src now resolves; failure shifts to `pnpmDeps` with another
`hash mismatch` block. Copy the `got: sha256-...` into
`pnpmDeps.hash`.

- [ ] **Step 5: Build full package**

```bash
nix build .#stasharr-portal 2>&1 | tee /tmp/build.log
```

Expected: succeeds. If a different failure appears, capture it. Likely
candidates and fixes:

- `argon2.node not found at runtime` → `pnpm rebuild argon2` produced
  output in a non-default path; check `node_modules/argon2/build/Release/`
  for the `.node` file.
- `prisma generate` fails with DATABASE_URL related error → ensure the
  placeholder `DATABASE_URL=postgresql://placeholder:...` is set in
  the same shell line as the prisma command.
- `pnpm install --frozen-lockfile` fails with ERR_PNPM_OUTDATED_LOCKFILE
  or a lockfile-version error → pnpm 10.29.2 vs 10.32.0 incompatibility;
  fall back to OCI per the Decision space deferred section.
- Angular build complains about telemetry → confirm
  `env.NG_CLI_ANALYTICS = "ci";` is set.

- [ ] **Step 6: Smoke-test the entrypoint exists**

```bash
ls -la result/bin/stasharr-portal result/share/stasharr-portal/start-app.sh
result/bin/stasharr-portal --help 2>&1 | head -5 || true
```

Expected: both files exist. The wrapper run produces some node-level
error about missing env (DATABASE_URL etc.) — that's fine; we just
verify the binary is reachable.

- [ ] **Step 7: Commit**

```bash
git add package-sets/top-level/stasharr-portal/default.nix
git commit -m "package-sets/top-level/stasharr-portal: package v0.1.0"
```

### Phase 3 — `theonecfg.services.stasharr`

#### Task 3.1 — Stasharr module skeleton

**Files:**

- Create: `nixos-modules/services/stasharr/module.nix`

**Steps:**

- [ ] **Step 1: Create the module file**

Write `nixos-modules/services/stasharr/module.nix` per the design in
Phase 3 above. Include the `pgInstance` let-binding (this is the line
the design phase didn't show explicitly):

```nix
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) bool int str;

  cfg = config.theonecfg.services.stasharr;
  pgInstance = config.theonecfg.services.postgres.instances.stasharr;
in
{ ... }
```

Implement: option block, `users.users.stasharr` + `users.groups.stasharr`,
`theonecfg.services.postgres.instances.stasharr`, the systemd unit
exactly as in the design, sops secret + template, and the Caddy vhost
under `mkIf config.theonecfg.services.caddy.enable`.

- [ ] **Step 2: Track the new file**

```bash
git add -N nixos-modules/services/stasharr/module.nix
```

- [ ] **Step 3: Run flake check**

```bash
nix flake check
```

Expected: passes (module not enabled anywhere yet).

- [ ] **Step 4: Commit**

```bash
git add nixos-modules/services/stasharr/module.nix
git commit -m "nixos-modules/services/stasharr: new module — Stasharr Portal"
```

#### Task 3.2 — Enable Stasharr on scheelite (declarative)

**Files:**

- Modify: `nixos-configurations/scheelite/default.nix`
- Modify: `nixos-configurations/scheelite/disko.nix`

**Steps:**

- [ ] **Step 1: Add the service block to scheelite/default.nix**

Inside the `theonecfg.services` attrset (near the existing `stash`
block from Task 1.3), add:

```nix
stasharr = {
  enable = true;
  dataDir = "${tankServicesDir}/stasharr";
};
```

Outside `theonecfg.services`:

```nix
sops.secrets."stasharr/postgres-password".owner = "stasharr";
```

- [ ] **Step 2: Add the postgres password to sops**

```bash
echo "stasharr/postgres-password = $(openssl rand -base64 32)"
sops secrets/scheelite.yaml
```

Add under existing top-level keys:

```yaml
stasharr:
    postgres-password: <paste the generated value>
```

Save and exit.

- [ ] **Step 3: Add disko datasets**

In `disko.nix`:

Under `scheelite-tank0.datasets`:

```nix
"tank0/services/stasharr" = {
  type = "zfs_fs";
  mountpoint = "/tank0/services/stasharr";
  options.mountpoint = "/tank0/services/stasharr";
};
```

Under `scheelite-root.datasets`:

```nix
"safe/persist/postgres/stasharr" = {
  type = "zfs_fs";
  mountpoint = "/persist/postgres/stasharr";
  options = {
    mountpoint = "/persist/postgres/stasharr";
    recordsize = "16K";
    atime = "off";
  };
};
```

- [ ] **Step 4: Build the toplevel**

```bash
nix build .#nixosConfigurations.scheelite.config.system.build.toplevel
```

Expected: succeeds.

- [ ] **Step 5: Commit**

```bash
git add nixos-configurations/scheelite/default.nix \
        nixos-configurations/scheelite/disko.nix \
        secrets/scheelite.yaml
git commit -m "nixos-configurations/scheelite: enable Stasharr Portal"
```

#### Task 3.3 — Create datasets on live scheelite + deploy + verify

**Operational task** (no commit).

**Steps:**

- [ ] **Step 1: SSH to scheelite and create the datasets**

```bash
ssh scheelite
sudo zfs create scheelite-tank0/tank0/services/stasharr
sudo zfs create -o recordsize=16K -o atime=off \
  scheelite-root/safe/persist/postgres/stasharr
zfs list scheelite-tank0/tank0/services/stasharr scheelite-root/safe/persist/postgres/stasharr
```

Expected: both datasets listed.

- [ ] **Step 2: Deploy**

```bash
nixos-rebuild --flake .#scheelite --target-host scheelite --sudo --ask-sudo-password switch
```

Expected: switch succeeds.

- [ ] **Step 3: Verify postgres container starts**

```bash
ssh scheelite "systemctl status container@postgres-stasharr --no-pager | head -15"
```

Expected: `active (running)`. Note: `container@postgres-stasharr.service`
is the templated unit name — the postgres helper creates
`containers.\"postgres-stasharr\"` which NixOS realizes via the
template.

- [ ] **Step 4: Verify Stasharr starts**

```bash
ssh scheelite "systemctl status stasharr --no-pager | head -20"
ssh scheelite "journalctl -u stasharr --since '5 minutes ago' --no-pager | tail -30"
```

Expected sequence in journalctl:

- `Loaded persisted session secret from ...` (or
  `Generated and persisted a session secret at ...` on first run)
- `Derived DATABASE_URL for 10.233.X.2:5432 from shared POSTGRES_*`
- `Applying Prisma migrations`
- `Starting Stasharr`
- `Nest application successfully started` (NestJS startup line)

If `prisma migrate deploy` errors with a Prisma protocol-mismatch
message, capture the exact text and fall back to OCI per the
Decision space deferred section.

- [ ] **Step 5: Verify Caddy + UI reachable**

In a browser: `https://stasharr.scheelite.dev`. Expected: kanidm
forward-auth challenge, then the Stasharr Portal bootstrap screen.

### Final integration

#### Task 4.1 — Bootstrap admin + configure integrations in Stasharr UI

**Operational task** (no commit).

**Steps:**

- [ ] **Step 1: Bootstrap the local admin account**

In the Stasharr Portal bootstrap screen, create the local-admin user
(this is Stasharr's own login on top of Kanidm's gate; double-auth is
expected per the design).

- [ ] **Step 2: Configure Whisparr integration**

Settings → Integrations → Whisparr:

- URL: `http://127.0.0.1:6969`
- API key: from `secrets/scheelite.yaml` `whisparr/api-key`
  (read with `sops --decrypt secrets/scheelite.yaml | grep -A1 whisparr`)
- Click Test → expect green/CONFIGURED.

- [ ] **Step 3: Configure Stash integration**

In Stash UI → Settings → Security → API Key, generate a new key and copy.

In Stasharr UI → Settings → Integrations → Stash:

- URL: `http://127.0.0.1:9999`
- API key: paste the value from Stash.
- Click Test → expect green/CONFIGURED.

- [ ] **Step 4: Configure StashDB catalog provider**

Settings → Integrations → StashDB:

- URL: `https://stashdb.org/graphql`
- API key: same StashDB token added to sops in Task 0.1.
- Click Test → expect green/CONFIGURED.

#### Task 4.2 — End-to-end scene-request smoke test

**Operational task** (no commit).

**Steps:**

- [ ] **Step 1: Browse a StashDB scene in Stasharr**

In Stasharr UI → Discover or browse via studios/performers. Pick any
catalogued scene.

- [ ] **Step 2: Request the scene**

Click Request. Expected: UI confirms the request was sent.

- [ ] **Step 3: Confirm Whisparr received it**

```bash
ssh scheelite "curl -fsS -H \"X-Api-Key: \$(sudo cat /run/secrets/whisparr/api-key)\" http://127.0.0.1:6969/api/v3/movie | jq '.[].title'" | tail -5
```

Expected: requested scene appears in the Whisparr movie list.

- [ ] **Step 4: Confirm local-availability badge for an existing scene**

In Stasharr UI, find a scene that's already in your `/tank0/media/adult`
library and was scanned by Stash in Task 1.4. Expected: the scene's
tile shows a "local" availability badge (Stasharr's
`stashAvailable=true` flag from the Stash adapter).

If badge missing: confirm Stasharr's runtime-health → STASH service is
HEALTHY in Settings → Integrations.
