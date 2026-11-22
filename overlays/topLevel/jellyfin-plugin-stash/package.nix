{
  lib,
  buildDotnetModule,
  fetchFromGitHub,
  dotnetCorePackages,
}:

let
  # Upstream's last tagged release (1.2.0.3) targets Jellyfin 10.11. The
  # Jellyfin 12 port lives only on main (commit "update to jellyfin 12",
  # published as the untagged "latest" development build); the assembly
  # version there is still 1.2.0.3.
  pluginVersion = "1.2.0.3";
  metaJson = builtins.toFile "meta.json" (
    builtins.toJSON {
      category = "Metadata";
      name = "Stash";
      owner = "DirtyRacer";
      description = "";
      overview = "";
      guid = "57b8ef5d-8835-436d-9514-a709ee25faf2";
      version = pluginVersion;
      targetAbi = "12.0.0.0";
      changelog = "update to jellyfin 12";
      timestamp = "2026-09-10T00:34:36Z";
      autoUpdate = false;
      imagePath = "";
      status = "Active";
      assemblies = [ "Jellyfin.Plugin.Stash.dll" ];
    }
  );
in

buildDotnetModule (finalAttrs: {
  pname = "jellyfin-plugin-stash";
  version = "${pluginVersion}-unstable-2026-09-10";

  src = fetchFromGitHub {
    owner = "DirtyRacer1337";
    repo = "Jellyfin.Plugin.Stash";
    rev = "b1ab78b044f1202f40d7b40b8ec737f0f33323cd";
    hash = "sha256-tguFEVYjR5ZImHOVSuM6mzTYMkuZ6IxYD8l+uQlYvdo=";
  };

  projectFile = "Jellyfin.Plugin.Stash/Stash.csproj";
  nugetDeps = ./deps.json;

  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.runtime_10_0;

  # Plugin is library-only; no executables to wrap into $out/bin.
  executables = [ ];

  # The `net10.0` segment must match the upstream csproj's <TargetFramework>;
  # the `linux-x64` segment is `dotnet-sdk`'s default runtime ID for this
  # platform. Both will need updating if upstream bumps target framework
  # or if the build is cross-targeted.
  #
  # ILRepack (which the upstream Windows CI uses to merge Newtonsoft.Json
  # into a single Stash.dll) does not run cleanly under `dotnet build` on
  # Linux, so install both DLLs separately. Jellyfin's plugin loader picks
  # up whatever's in the plugin folder.
  #
  # meta.json is generated from the values in upstream's manifest.json for
  # this version. Without it, Jellyfin falls back to parsing the directory
  # name for display metadata, which produces "jellyfin-plugin-stash" instead
  # of "Stash". The json content tracks upstream's manifest.json entry for
  # the installed version.
  installPhase = ''
    runHook preInstall
    install -d $out/share/jellyfin-plugin-stash
    cp Jellyfin.Plugin.Stash/bin/Release/net10.0/linux-x64/Stash.dll \
       $out/share/jellyfin-plugin-stash/Jellyfin.Plugin.Stash.dll
    cp Jellyfin.Plugin.Stash/bin/Release/net10.0/linux-x64/Newtonsoft.Json.dll \
       $out/share/jellyfin-plugin-stash/Newtonsoft.Json.dll
    install -m644 ${metaJson} $out/share/jellyfin-plugin-stash/meta.json
    runHook postInstall
  '';

  meta = {
    description = "Jellyfin metadata plugin pulling adult-content scenes from a local Stash instance";
    homepage = "https://github.com/DirtyRacer1337/Jellyfin.Plugin.Stash";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
})
