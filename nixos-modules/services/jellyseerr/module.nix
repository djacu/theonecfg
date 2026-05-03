{
  config,
  lib,
  pkgs,
  theonecfg,
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
    int
    str
    ;

  cfg = config.theonecfg.services.jellyseerr;
  declarative = theonecfg.library.declarative pkgs;

  baseUrl = "http://127.0.0.1:${toString cfg.port}";

  jellyfinCfg = config.theonecfg.services.jellyfin;
  sonarrCfg = config.theonecfg.services.sonarr;
  sonarrAnimeCfg = config.theonecfg.services.sonarr-anime;
  radarrCfg = config.theonecfg.services.radarr;

  jellyfinBaseUrl = "http://127.0.0.1:${toString jellyfinCfg.port}";

  # Build the list of *arr instances to register with Seerr post-bootstrap.
  # Each entry is { kind, name, baseUrl, apiKeyFile, rootFolder, isDefault, is4k, ...kind-specific }.
  # Each *arr's rootFolder for Seerr is the first entry from its configured
  # rootFolders list. If you want a different folder, expose it via the
  # *arr's rootFolders or override here.
  arrInstances =
    lib.optional (sonarrCfg.enable && sonarrCfg.rootFolders != [ ]) {
      kind = "sonarr";
      name = "Sonarr";
      arrBaseUrl = "http://127.0.0.1:${toString sonarrCfg.port}";
      arrApiKeyFile = config.sops.secrets."sonarr/api-key".path;
      rootFolder = (lib.head sonarrCfg.rootFolders).path;
      isDefault = true;
      is4k = true;
      seriesType = "standard";
    }
    ++ lib.optional (sonarrAnimeCfg.enable && sonarrAnimeCfg.rootFolders != [ ]) {
      kind = "sonarr";
      name = "Sonarr (Anime)";
      arrBaseUrl = "http://127.0.0.1:${toString sonarrAnimeCfg.port}";
      arrApiKeyFile = config.sops.secrets."sonarr-anime/api-key".path;
      rootFolder = (lib.head sonarrAnimeCfg.rootFolders).path;
      isDefault = false;
      is4k = false;
      seriesType = "anime";
    }
    ++ lib.optional (radarrCfg.enable && radarrCfg.rootFolders != [ ]) {
      kind = "radarr";
      name = "Radarr";
      arrBaseUrl = "http://127.0.0.1:${toString radarrCfg.port}";
      arrApiKeyFile = config.sops.secrets."radarr/api-key".path;
      rootFolder = (lib.head radarrCfg.rootFolders).path;
      isDefault = true;
      is4k = true;
    };

  arrInstancesFile = pkgs.writeText "seerr-arr-instances.json" (builtins.toJSON arrInstances);

in
{
  options.theonecfg.services.jellyseerr = {
    enable = mkEnableOption "Jellyseerr / Seerr (media request platform)";
    domain = mkOption {
      type = str;
      default = "jellyseerr.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 5055;
    };
    jellyfinAdminEmail = mkOption {
      type = str;
      default = theonecfg.knownUsers.${jellyfinCfg.adminUser}.email;
      defaultText = lib.literalExpression "theonecfg.knownUsers.\${jellyfin.adminUser}.email";
      description = "Email used for the Seerr admin user (created via Jellyfin auth). Defaults to the email of the user named in jellyfin.adminUser, looked up in theonecfg.knownUsers.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Renamed to Seerr in NixOS 26.05; the option still works under either
      # name via a renamed-option module shim. State dir is /var/lib/seerr.
      services.seerr = {
        enable = true;
        port = cfg.port;
      };

      # State lives at /var/lib/seerr (created by services.seerr); on hosts
      # that roll back root state (impermanence), the host's impermanence
      # config must list /var/lib/seerr among the persisted directories.

      sops.secrets."jellyseerr/admin-password".owner = "seerr";
    }

    # Bootstrap one-shot. Logs into Seerr via Jellyfin (creating the Seerr
    # admin user tied to the Jellyfin admin), registers each enabled *arr
    # via /api/v1/settings/{sonarr,radarr}, then POSTs /api/v1/settings/initialize.
    #
    # Idempotent: skips if /api/v1/settings/public.initialized is already true.
    {
      systemd.services.jellyseerr-bootstrap = {
        description = "Bootstrap Jellyseerr admin + *arr connections";
        after = [
          "seerr.service"
          "jellyfin.service"
          "jellyfin-bootstrap.service"
        ]
        ++ lib.optional sonarrCfg.enable "sonarr.service"
        ++ lib.optional sonarrAnimeCfg.enable "sonarr-anime.service"
        ++ lib.optional radarrCfg.enable "radarr.service";
        requires = [ "seerr.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          ${declarative.waitForApiScript {
            url = "${baseUrl}/api/v1/status";
          }}

          # Idempotency check
          public=$(curl -fsS "${baseUrl}/api/v1/settings/public")
          if [ "$(jq -r '.initialized' <<< "$public")" = "true" ]; then
            echo "Jellyseerr already initialized; skipping bootstrap."
            exit 0
          fi

          echo "Jellyseerr first-run bootstrap starting..."

          # Wait for Jellyfin to be reachable (needed for auth/jellyfin call)
          ${declarative.waitForApiScript {
            url = "${jellyfinBaseUrl}/System/Info/Public";
          }}

          # Read Jellyfin admin password
          jf_password=$(tr -d '\n' < "${config.sops.secrets."jellyfin/admin-password".path}")

          # Login via Jellyfin — creates Seerr admin user tied to the Jellyfin admin.
          # Saves session cookie.
          cookie_jar=$(mktemp)
          trap 'rm -f "$cookie_jar"' EXIT

          curl -fsS -c "$cookie_jar" -X POST "${baseUrl}/api/v1/auth/jellyfin" \
            -H "Content-Type: application/json" \
            -d "$(jq -nc \
              --arg user "${jellyfinCfg.adminUser}" \
              --arg pass "$jf_password" \
              --arg host "${jellyfinBaseUrl}" \
              --arg email "${cfg.jellyfinAdminEmail}" \
              '{
                username: $user,
                password: $pass,
                hostname: $host,
                email: $email,
                serverType: 2
              }')" >/dev/null

          echo "Logged in to Seerr via Jellyfin."

          # Helper: POST a Seerr setting using the cookie jar
          seerr_post() {
            local path="$1" body="$2"
            curl -fsS -b "$cookie_jar" -X POST "${baseUrl}$path" \
              -H "Content-Type: application/json" \
              -d "$body"
          }

          # For each *arr instance: query its quality profiles, then register with Seerr.
          while read -r instance; do
            kind=$(jq -r '.kind' <<< "$instance")
            name=$(jq -r '.name' <<< "$instance")
            arrUrl=$(jq -r '.arrBaseUrl' <<< "$instance")
            keyfile=$(jq -r '.arrApiKeyFile' <<< "$instance")
            rootFolder=$(jq -r '.rootFolder' <<< "$instance")
            isDefault=$(jq -r '.isDefault' <<< "$instance")
            is4k=$(jq -r '.is4k' <<< "$instance")

            arrKey=$(tr -d '\n' < "$keyfile")

            # Wait for the *arr API
            until curl -fsS -H "X-Api-Key: $arrKey" "$arrUrl/api/v3/system/status" >/dev/null 2>&1; do
              sleep 2
            done

            # Pick the first quality profile available (Recyclarr will populate
            # TRaSH-curated profiles separately; if you want to pin a specific
            # profile, change this to a name lookup).
            profiles=$(curl -fsS -H "X-Api-Key: $arrKey" "$arrUrl/api/v3/qualityprofile")
            profileId=$(jq '.[0].id' <<< "$profiles")
            profileName=$(jq -r '.[0].name' <<< "$profiles")

            # hostname / port pulled from the URL for Seerr's data model
            arrHost="127.0.0.1"
            arrPort=$(echo "$arrUrl" | sed 's|.*://[^:]*:||; s|/.*||')

            echo "Registering $name with Seerr (profile: $profileName, root: $rootFolder)"

            if [ "$kind" = "sonarr" ]; then
              seriesType=$(jq -r '.seriesType' <<< "$instance")
              body=$(jq -nc \
                --arg name "$name" \
                --arg host "$arrHost" \
                --argjson port "$arrPort" \
                --arg key "$arrKey" \
                --argjson profileId "$profileId" \
                --arg profileName "$profileName" \
                --arg root "$rootFolder" \
                --argjson isDefault "$isDefault" \
                --argjson is4k "$is4k" \
                --arg seriesType "$seriesType" \
                '{
                  name: $name,
                  hostname: $host,
                  port: $port,
                  apiKey: $key,
                  useSsl: false,
                  baseUrl: "/",
                  activeProfileId: $profileId,
                  activeProfileName: $profileName,
                  activeDirectory: $root,
                  tags: [],
                  is4k: $is4k,
                  isDefault: $isDefault,
                  syncEnabled: true,
                  preventSearch: false,
                  tagRequests: false,
                  overrideRule: [],
                  seriesType: $seriesType,
                  animeSeriesType: "anime",
                  enableSeasonFolders: true,
                  monitorNewItems: "all"
                }')
              seerr_post /api/v1/settings/sonarr "$body" >/dev/null

            elif [ "$kind" = "radarr" ]; then
              body=$(jq -nc \
                --arg name "$name" \
                --arg host "$arrHost" \
                --argjson port "$arrPort" \
                --arg key "$arrKey" \
                --argjson profileId "$profileId" \
                --arg profileName "$profileName" \
                --arg root "$rootFolder" \
                --argjson isDefault "$isDefault" \
                --argjson is4k "$is4k" \
                '{
                  name: $name,
                  hostname: $host,
                  port: $port,
                  apiKey: $key,
                  useSsl: false,
                  baseUrl: "/",
                  activeProfileId: $profileId,
                  activeProfileName: $profileName,
                  activeDirectory: $root,
                  tags: [],
                  is4k: $is4k,
                  isDefault: $isDefault,
                  syncEnabled: true,
                  preventSearch: false,
                  tagRequests: false,
                  overrideRule: [],
                  minimumAvailability: "released"
                }')
              seerr_post /api/v1/settings/radarr "$body" >/dev/null
            fi

          done < <(jq -c '.[]' ${arrInstancesFile})

          # Mark setup complete
          curl -fsS -b "$cookie_jar" -X POST "${baseUrl}/api/v1/settings/initialize" >/dev/null

          echo "Jellyseerr bootstrap complete."
        '';
      };
    }

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
