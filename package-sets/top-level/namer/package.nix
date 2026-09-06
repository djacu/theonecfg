{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPypi,
  buildGoModule,
  python312Packages,
  nodejs_22,
  pnpm,
  pnpmConfigHook,
  fetchPnpmDeps,
  ffmpeg,
}:

let
  version = "1.19.20";

  src = fetchFromGitHub {
    owner = "ThePornDatabase";
    repo = "namer";
    tag = "v${version}";
    hash = "sha256-YgZiPE//WaxotzaOBY4SlBqXMYozzNnIspj0pXHSFjQ=";
  };

  # namer's DEFAULT, canonical perceptual-hash generator (StashVideoPerceptualHash).
  # It reimplements Stash's phash via `github.com/stashapp/stash`, so the hashes it
  # produces match the phashes indexed by StashDB/TPDb — the pure-python fallback
  # (`use_alt_phash_tool = true`) is documented as "not 100% compatible". Pure Go,
  # no cgo; it shells out to ffmpeg/ffprobe at runtime (provided on PATH below).
  videohashes = buildGoModule {
    pname = "videohashes";
    version = "0-unstable-2024-12-07";

    src = fetchFromGitHub {
      owner = "ThePornDatabase";
      repo = "videohashes";
      rev = "5dc5ce67fc4bd32900a46342bf42d38ac1e826f6";
      hash = "sha256-JKQLO+xrV5nDZxRycQa8ZMhEZrtVo7kFcTIWIdnqK04=";
    };

    vendorHash = "sha256-brVDKPaFjOiE2M1l296v3V9Xy7D3xMPAofQBQUHtV7A=";

    subPackages = [ "cmd/videohashes" ];

    meta = {
      description = "Stash-compatible perceptual hashing tool for video files";
      homepage = "https://github.com/ThePornDatabase/videohashes";
      # Upstream declares no LICENSE file; it links github.com/stashapp/stash
      # (AGPL-3.0), so the derivative is treated as AGPL-3.0 here.
      license = lib.licenses.agpl3Only;
      mainProgram = "videohashes";
    };
  };

  # webpack/pnpm frontend for the watchdog web UI. `pnpm run build` emits
  # namer/web/public/assets + namer/web/templates, which poetry's `include`
  # globs bundle into the wheel.
  namer-web = stdenv.mkDerivation (finalAttrs: {
    pname = "namer-web";
    inherit version src;

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-toazMdRXBQYpXP2peIJvb6p0I7Q2QiCFIDE2jDeMVDk=";
    };

    nativeBuildInputs = [
      nodejs_22
      pnpm
      pnpmConfigHook
    ];

    buildPhase = ''
      runHook preBuild
      pnpm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r namer/web/public/assets $out/assets
      cp -r namer/web/templates $out/templates
      runHook postInstall
    '';
  });

  # Not in nixpkgs. Tiny pure-python implementation of the OpenSubtitles hash.
  oshash = python312Packages.buildPythonPackage rec {
    pname = "oshash";
    version = "0.1.1";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-frff3X2XbToG/MFLqM+CZc04fJnle90xDgq4R7e38Lc=";
    };

    doCheck = false;
    pythonImportsCheck = [ "oshash" ];

    meta = {
      description = "Implementation of OpenSubtitles hash in Python";
      homepage = "https://pypi.org/project/oshash/";
      license = lib.licenses.gpl3Only;
      mainProgram = "oshash";
    };
  };

in
python312Packages.buildPythonApplication {
  pname = "namer";
  inherit version src;
  pyproject = true;

  build-system = [ python312Packages.poetry-core ];

  dependencies = with python312Packages; [
    rapidfuzz
    watchdog
    pathvalidate
    requests
    mutagen
    schedule
    loguru
    unidecode
    flask
    waitress
    flask-compress
    pillow
    requests-cache
    ffmpeg-python
    jsonpickle
    configupdater
    oshash
    pony
    numpy
    scipy
    orjson
  ];

  # namer pins tight upper bounds (numpy <2.4, Pillow ^12, ...) that don't all
  # match nixpkgs; relax so the wheel-metadata conflict check passes.
  pythonRelaxDeps = true;

  # Inject the generated web assets + the prebuilt videohashes binary into the
  # tree before poetry builds the wheel (poetry `include` bundles
  # namer/tools/videohashes* and namer/web/{public/assets,templates}).
  # namer's StashVideoPerceptualHash looks for namer/tools/videohashes-amd64-linux.
  preBuild = ''
    cp -r ${namer-web}/assets namer/web/public/assets
    cp -r ${namer-web}/templates namer/web/templates
    mkdir -p namer/tools
    install -m0755 ${videohashes}/bin/videohashes namer/tools/videohashes-amd64-linux
  '';

  # Ensure the bundled phash binary stays executable after wheel install.
  postInstall = ''
    find $out -name 'videohashes-amd64-linux' -exec chmod +x {} +
  '';

  # ffmpeg + ffprobe on PATH for both namer (ffmpeg-python) and the videohashes
  # subprocess (which looks for ff* on PATH, else tries to self-download).
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ ffmpeg ])
  ];

  pythonImportsCheck = [ "namer" ];

  meta = {
    description = "Renames and tags adult video files using ThePornDB metadata (phash + name matching)";
    homepage = "https://github.com/ThePornDatabase/namer";
    license = lib.licenses.mit;
    mainProgram = "namer";
    platforms = lib.platforms.linux;
  };
}
