{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  python3,
  wayland-scanner,
  makeWrapper,
  autoAddDriverRunpath,
  wayland,
  wayland-protocols,
  libglvnd,
  libxkbcommon,
  freetype,
  fontconfig,
  cairo,
  glib,
  curl,
  libxml2,
  pango,
  harfbuzz,
  libpng,
  libarchive,
  xz,
  acl,
  libwebp,
  gdk-pixbuf,
  librsvg,
  stb,
  nlohmann_json,
  tomlplusplus,
  # runtime
  gvfs,
  glib-networking,
  dconf,
  gsettings-desktop-schemas,
  adwaita-icon-theme,
  shared-mime-info,
  xdg-terminal-exec,
  ffmpeg,
  ffmpegthumbnailer,
  poppler-utils,
  _7zz,
}:

let
  rev = "b712149b0793616ecb35ad30c55a558e773a9372";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "luciole";
  # No release tags yet; VERSION in the tree reads 0.1.0.
  version = "0.1.0-unstable-2026-11-26";

  src = fetchFromGitHub {
    owner = "noctalia-dev";
    repo = "luciole";
    inherit rev;
    hash = "sha256-Q2PZ6oDj9H7tnuIkL4edWs/XAokyLzpvaIjWgmKaD5A=";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    python3
    wayland-scanner
    makeWrapper
    autoAddDriverRunpath
  ];

  buildInputs = [
    wayland
    wayland-protocols
    libglvnd
    libxkbcommon
    freetype
    fontconfig
    cairo
    glib
    curl
    libxml2
    pango
    harfbuzz
    libpng
    libarchive
    xz
    acl
    libwebp
    gdk-pixbuf
    librsvg
    stb
    nlohmann_json
    tomlplusplus
  ];

  mesonBuildType = "release";

  mesonFlags = [
    (lib.mesonEnable "tests" false)
    (lib.mesonOption "build_revision" (builtins.substring 0 12 rev))
  ];

  # Helpers Luciole runs for terminals, thumbnails, PDFs and encrypted 7z,
  # and the GIO modules, schemas, icons and MIME data its PACKAGING.md lists.
  # The GVfs daemons themselves come from services.gvfs on the system.
  postFixup = ''
    wrapProgram "$out/bin/luciole" \
      --suffix PATH : "${
        lib.makeBinPath [
          xdg-terminal-exec
          ffmpeg
          ffmpegthumbnailer
          poppler-utils
          _7zz
        ]
      }" \
      --suffix GIO_EXTRA_MODULES : "${
        lib.makeSearchPath "lib/gio/modules" [
          gvfs
          glib-networking
          dconf.lib
        ]
      }" \
      --suffix XDG_DATA_DIRS : "${glib.getSchemaDataDirPath gsettings-desktop-schemas}:${
        lib.makeSearchPath "share" [
          adwaita-icon-theme
          shared-mime-info
        ]
      }"
  '';

  meta = {
    description = "Native Wayland file manager from the Noctalia project";
    homepage = "https://github.com/noctalia-dev/luciole";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "luciole";
  };
})
