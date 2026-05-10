{
  stdenv,
  lib,
  fetchFromGitHub,
  nodejs_22,
  pnpm,
  pnpmConfigHook,
  fetchPnpmDeps,
  prisma-engines_7,
  openssl,
  python3,
  makeWrapper,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "stasharr-portal";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "enymawse";
    repo = "stasharr-portal";
    tag = "v${finalAttrs.version}";
    hash = "sha256-i6KihU+ygUAlmWk6RsIEhJzCsIcqA2FCi6SjcO94MyQ=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 3;
    hash = "sha256-ydnE3FLlPt3HeIQawYlO9DGGtEcSQbXJyRrrmk4IgVg=";
  };

  nativeBuildInputs = [
    nodejs_22
    pnpm
    pnpmConfigHook
    prisma-engines_7
    python3
    makeWrapper
  ];

  buildInputs = [ openssl ];

  env = {
    PRISMA_SCHEMA_ENGINE_BINARY = "${prisma-engines_7}/bin/schema-engine";
    NG_CLI_ANALYTICS = "ci";
  };

  buildPhase = ''
    runHook preBuild

    # pnpm.configHook ran `pnpm install --offline --ignore-scripts
    # --frozen-lockfile`, which skips argon2's postinstall native
    # build. Force the rebuild explicitly so the runtime closure
    # has the compiled .node binary.
    pnpm rebuild argon2

    # Prisma 7 client generation; needs DATABASE_URL set even just
    # to generate (validated against upstream Dockerfile lines 13-14
    # at /tmp/investigate/stasharr-portal/Dockerfile).
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

    # Match the Dockerfile's runtime-image layout (/tmp/investigate/
    # stasharr-portal/Dockerfile lines 30-39). cp -r preserves pnpm's
    # symlink-farm node_modules layout (no -L).
    #
    # `prisma.config.ts` is intentionally NOT installed: upstream's
    # config file imports `dotenv/config`, which is a transitive
    # dep that pnpm leaves only under .pnpm/ (not top-level
    # node_modules). Without the config file, prisma reads the
    # datasource url from schema.prisma's `url = env(...)` line —
    # which upstream's schema doesn't have (the url lives in
    # prisma.config.ts). Patch schema.prisma below to add it.
    cp -r package.json node_modules prisma \
          $out/share/stasharr-portal/

    # Inject `url = env("DATABASE_URL")` into datasource db (see
    # comment above on prisma.config.ts removal).
    sed -i '/provider = "postgresql"/a\  url      = env("DATABASE_URL")' \
      $out/share/stasharr-portal/prisma/schema.prisma
    cp -r apps/sp-api/dist apps/sp-api/node_modules apps/sp-api/package.json \
          $out/share/stasharr-portal/apps/sp-api/
    cp -r apps/sp-web/dist $out/share/stasharr-portal/apps/sp-web/

    # Reuse upstream's bootstrap entrypoint. Patch absolute /app/
    # paths (Docker WORKDIR=/app) to relative; the systemd unit will
    # set WorkingDirectory accordingly.
    install -m 0755 infrastructure/docker/start-app.sh \
      $out/share/stasharr-portal/start-app.sh
    substituteInPlace $out/share/stasharr-portal/start-app.sh \
      --replace-fail '/app/' './'

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
