{
  lib,
  buildDotnetModule,
  fetchFromGitHub,
  dotnetCorePackages,
}:

buildDotnetModule (finalAttrs: {
  pname = "jellyfin-plugin-stash";
  version = "1.2.0.3";

  src = fetchFromGitHub {
    owner = "DirtyRacer1337";
    repo = "Jellyfin.Plugin.Stash";
    tag = finalAttrs.version;
    hash = "sha256-xMfafgK0gA+4w+wt11l5Giow7OCmqprP24eS4apycoY=";
  };

  projectFile = "Jellyfin.Plugin.Stash/Stash.csproj";
  nugetDeps = ./deps.json;

  dotnet-sdk = dotnetCorePackages.sdk_9_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_9_0;

  # Plugin is library-only; no executables to wrap into $out/bin.
  executables = [ ];

  # Default install runs `dotnet publish` and dumps everything into
  # $out/lib/<pname>/. We only want the plugin dlls. Override.
  # ILRepack does not run on Linux; install Stash.dll + Newtonsoft.Json.dll.
  installPhase = ''
    runHook preInstall
    install -d $out/share/jellyfin-plugin-stash
    cp Jellyfin.Plugin.Stash/bin/Release/net9.0/linux-x64/Stash.dll \
       $out/share/jellyfin-plugin-stash/Jellyfin.Plugin.Stash.dll
    cp Jellyfin.Plugin.Stash/bin/Release/net9.0/linux-x64/Newtonsoft.Json.dll \
       $out/share/jellyfin-plugin-stash/Newtonsoft.Json.dll
    runHook postInstall
  '';

  meta = {
    description = "Jellyfin metadata plugin pulling adult-content scenes from a local Stash instance";
    homepage = "https://github.com/DirtyRacer1337/Jellyfin.Plugin.Stash";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
})
