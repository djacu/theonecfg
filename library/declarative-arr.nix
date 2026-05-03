/**
  Helpers for declarative configuration of media-server REST APIs.

  Pattern: each helper returns a NixOS module fragment that defines a systemd
  one-shot. The one-shot waits for the target API to be ready, GETs current
  state, diffs against a Nix-declared desired state, and POST/PUT/DELETEs to
  reconcile. Idempotent.

  Used by *arr / Jellyfin / qBittorrent / Seerr modules. Composable via
  mkMerge.

  Pattern adapted from nixflix's mkArrServiceModule + mkSecureCurl + waitForApi
  helpers, simplified for our use case. Config-file templating is not used;
  the *arr stack accepts env-var injection natively (.NET .AddEnvironmentVariables()),
  and qBittorrent's password seeding is a single ExecStartPre sed.
*/
{ lib, pkgs }:
lib.fix (self: {

  /**
    Wait until an HTTP endpoint responds with 200, with a timeout.

    Returns a Bash snippet usable inside `script` or `preStart`.
  */
  waitForApiScript =
    {
      url,
      timeout ? 300,
    }:
    ''
      end=$((SECONDS+${toString timeout}))
      until ${pkgs.curl}/bin/curl -fsSk --max-time 5 "${url}" >/dev/null 2>&1; do
        if [ $SECONDS -ge $end ]; then
          echo "Timeout waiting for ${url}" >&2
          exit 1
        fi
        sleep 2
      done
    '';

  /**
    Build an authenticated curl wrapper that injects an X-Api-Key header
    from a file. Returns a derivation; the binary is at
    `$out/bin/curl-${name}`.

    The wrapper also forces -fsS and JSON content-type. Use it for *arr
    REST clients.
  */
  mkSecureCurl =
    {
      name,
      apiKeyFile,
    }:
    pkgs.writeShellApplication {
      name = "curl-${name}";
      runtimeInputs = [
        pkgs.curl
        pkgs.jq
      ];
      text = ''
        if [ ! -r "${apiKeyFile}" ]; then
          echo "API key file not readable: ${apiKeyFile}" >&2
          exit 1
        fi
        apikey="$(tr -d '\n' < "${apiKeyFile}")"
        exec curl -fsS \
          -H "X-Api-Key: $apikey" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json" \
          "$@"
      '';
    };

  /**
    Generate a systemd one-shot that reconciles a list of items at an *arr
    REST endpoint. Returns a NixOS module fragment.

    Args:
      name        : systemd unit name (e.g. "sonarr-rootfolders")
      after       : list of units to order after (e.g. [ "sonarr.service" ])
      baseUrl     : http://127.0.0.1:8989
      apiKeyFile  : sops-resolved path
      endpoint    : /api/v3/rootfolder (no trailing slash)
      items       : list of attrs (Nix-declared desired state).
                    Each item must have the comparator field set.
      comparator  : field used to identify items for diff (default: "name")
      finalize    : optional jq filter applied to each desired item before
                    POST/PUT (e.g. ". + {enabled: true}")

    Behavior at runtime:
      1. Wait for ${baseUrl}${endpoint} to respond.
      2. GET current state.
      3. For each desired item: if comparator value matches an existing
         item by the same comparator, PUT (update by id); else POST (create).
      4. For each current item whose comparator value is NOT in desired,
         DELETE (cleans up drift).
  */
  mkArrApiPushService =
    {
      name,
      after,
      baseUrl,
      apiKeyFile,
      endpoint,
      items,
      comparator ? "name",
      finalize ? ".",
    }:
    let
      itemsFile = pkgs.writeText "${name}-items.json" (builtins.toJSON items);
      curlPkg = self.mkSecureCurl {
        inherit name apiKeyFile;
      };
    in
    {
      systemd.services.${name} = {
        description = "Reconcile ${endpoint} against declarative state";
        inherit after;
        requires = after;
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
          curlPkg
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          ${self.waitForApiScript {
            url = "${baseUrl}/api/v3/system/status";
          }}

          curl_cmd=curl-${name}

          current=$($curl_cmd "${baseUrl}${endpoint}")
          desired=$(jq '${finalize}' < ${itemsFile} | jq -c '.[]')

          # Collect existing items by comparator → id
          declare -A existing_ids
          while IFS=$'\t' read -r key id; do
            [ -n "$key" ] && existing_ids["$key"]="$id"
          done < <(jq -r ".[] | \"\(.${comparator})\\t\(.id)\"" <<< "$current")

          # Collect desired keys for later diff (delete pass)
          declare -A desired_keys
          while read -r item; do
            key=$(jq -r ".${comparator}" <<< "$item")
            desired_keys["$key"]=1

            if [ -n "''${existing_ids[$key]:-}" ]; then
              id="''${existing_ids[$key]}"
              payload=$(jq --argjson id "$id" '. + { id: $id }' <<< "$item")
              echo "PUT ${endpoint}/$id ($key)"
              $curl_cmd -X PUT -d "$payload" "${baseUrl}${endpoint}/$id" >/dev/null
            else
              echo "POST ${endpoint} ($key)"
              $curl_cmd -X POST -d "$item" "${baseUrl}${endpoint}" >/dev/null
            fi
          done <<< "$desired"

          # Delete pass — remove anything in current not in desired
          while IFS=$'\t' read -r key id; do
            if [ -n "$key" ] && [ -z "''${desired_keys[$key]:-}" ]; then
              echo "DELETE ${endpoint}/$id ($key)"
              $curl_cmd -X DELETE "${baseUrl}${endpoint}/$id" >/dev/null
            fi
          done < <(jq -r ".[] | \"\(.${comparator})\\t\(.id)\"" <<< "$current")
        '';
      };
    };

  /**
    Bootstrap Jellyfin's setup wizard via /Startup/* endpoints.
    All five endpoints accept requests without authentication BEFORE the
    wizard is marked complete. After /Startup/Complete, they require admin
    auth. So this one-shot is idempotent: if the wizard is already complete,
    the GET /Startup/Configuration returns 401 and we skip.

    Args:
      baseUrl
      serverName            : Jellyfin server name shown to clients
      uiCulture             : "en-US"
      metadataCountry       : "US"
      metadataLanguage      : "en"
      enableRemoteAccess    : bool — usually false (we use Caddy + Kanidm)
      adminUser             : username string
      adminPasswordFile     : sops-resolved file with plaintext password
  */
  mkJellyfinBootstrap =
    {
      baseUrl,
      serverName,
      uiCulture ? "en-US",
      metadataCountry ? "US",
      metadataLanguage ? "en",
      enableRemoteAccess ? false,
      adminUser,
      adminPasswordFile,
    }:
    {
      systemd.services.jellyfin-bootstrap = {
        description = "Bootstrap Jellyfin admin user via /Startup/* endpoints";
        after = [ "jellyfin.service" ];
        requires = [ "jellyfin.service" ];
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

          ${self.waitForApiScript {
            url = "${baseUrl}/System/Info/Public";
          }}

          # If the wizard is already complete, /Startup/Configuration returns 401.
          # Use that as our idempotency check.
          status=$(curl -s -o /dev/null -w "%{http_code}" "${baseUrl}/Startup/Configuration")
          if [ "$status" = "401" ]; then
            echo "Jellyfin wizard already complete; skipping bootstrap."
            exit 0
          fi

          # 1. POST /Startup/Configuration
          curl -fsS -X POST "${baseUrl}/Startup/Configuration" \
            -H "Content-Type: application/json" \
            -d ${
              lib.escapeShellArg (
                builtins.toJSON {
                  ServerName = serverName;
                  UICulture = uiCulture;
                  MetadataCountryCode = metadataCountry;
                  PreferredMetadataLanguage = metadataLanguage;
                }
              )
            }

          # 2. POST /Startup/User
          adminpass="$(tr -d '\n' < "${adminPasswordFile}")"
          curl -fsS -X POST "${baseUrl}/Startup/User" \
            -H "Content-Type: application/json" \
            -d "$(jq -nc \
              --arg user "${adminUser}" \
              --arg pass "$adminpass" \
              '{Name: $user, Password: $pass}')"

          # 3. POST /Startup/RemoteAccess
          curl -fsS -X POST "${baseUrl}/Startup/RemoteAccess" \
            -H "Content-Type: application/json" \
            -d ${
              lib.escapeShellArg (
                builtins.toJSON {
                  EnableRemoteAccess = enableRemoteAccess;
                  EnableAutomaticPortMapping = false;
                }
              )
            }

          # 4. POST /Startup/Complete
          curl -fsS -X POST "${baseUrl}/Startup/Complete"

          echo "Jellyfin bootstrap complete."
        '';
      };
    };

  /**
    Reconcile Jellyfin libraries (= /Library/VirtualFolders) against
    Nix-declared state. Authenticates as admin via /Users/AuthenticateByName,
    captures the AccessToken, then GET/POST/DELETE on /Library/VirtualFolders.

    Args:
      baseUrl
      adminUser
      adminPasswordFile
      libraries           : attrset name → { paths, type, options? }

    Notes on the library API:
      - POST /Library/VirtualFolders?name=X&collectionType=Y&paths=...
        creates a folder. paths is an array (use multiple ?paths= params).
      - DELETE /Library/VirtualFolders?name=X removes a folder.
      - GET   /Library/VirtualFolders returns the existing list (admin auth).
  */
  mkJellyfinLibrarySync =
    {
      baseUrl,
      adminUser,
      adminPasswordFile,
      libraries,
    }:
    let
      librariesFile = pkgs.writeText "jellyfin-libraries.json" (builtins.toJSON libraries);
    in
    {
      systemd.services.jellyfin-libraries = {
        description = "Reconcile Jellyfin libraries against declarative state";
        after = [ "jellyfin-bootstrap.service" ];
        requires = [ "jellyfin-bootstrap.service" ];
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

          ${self.waitForApiScript {
            url = "${baseUrl}/System/Info/Public";
          }}

          adminpass="$(tr -d '\n' < "${adminPasswordFile}")"

          # Authenticate as admin and capture token
          token=$(curl -fsS -X POST "${baseUrl}/Users/AuthenticateByName" \
            -H 'X-Emby-Authorization: MediaBrowser Client="theonecfg-bootstrap", Device="scheelite", DeviceId="bootstrap", Version="1"' \
            -H "Content-Type: application/json" \
            -d "$(jq -nc --arg u "${adminUser}" --arg p "$adminpass" '{Username:$u, Pw:$p}')" \
            | jq -r '.AccessToken')

          if [ -z "$token" ] || [ "$token" = "null" ]; then
            echo "Jellyfin auth failed" >&2
            exit 1
          fi

          auth=("-H" "X-Emby-Token: $token")

          desired=$(cat ${librariesFile})
          current=$(curl -fsS "${baseUrl}/Library/VirtualFolders" "''${auth[@]}")

          # Names of existing libraries
          existing_names=$(jq -r '.[].Name' <<< "$current")
          desired_names=$(jq -r 'keys[]' <<< "$desired")

          # Add missing
          for name in $desired_names; do
            if ! grep -qx "$name" <<< "$existing_names"; then
              echo "Adding Jellyfin library: $name"
              entry=$(jq -r --arg n "$name" '.[$n]' <<< "$desired")
              ctype=$(jq -r '.type' <<< "$entry")
              # Build query string with ?paths= per path
              query="name=$name&collectionType=$ctype&refreshLibrary=false"
              while read -r p; do
                query="$query&paths=$(jq -rn --arg s "$p" '$s | @uri')"
              done < <(jq -r '.paths[]' <<< "$entry")

              opts=$(jq -c '.options // {}' <<< "$entry")
              curl -fsS -X POST "${baseUrl}/Library/VirtualFolders?$query" \
                "''${auth[@]}" \
                -H "Content-Type: application/json" \
                -d "$opts" >/dev/null
            fi
          done

          # Delete extras
          for name in $existing_names; do
            if ! grep -qx "$name" <<< "$desired_names"; then
              echo "Removing Jellyfin library: $name"
              curl -fsS -X DELETE "${baseUrl}/Library/VirtualFolders?name=$(jq -rn --arg s "$name" '$s | @uri')" \
                "''${auth[@]}" >/dev/null
            fi
          done
        '';
      };
    };

  /**
    Push qBittorrent preferences and categories.
    Assumes qBittorrent is reachable on baseUrl from localhost (so the
    AuthSubnetWhitelist=127.0.0.1/32 bypass is in effect — no login needed).

    Args:
      baseUrl     : http://127.0.0.1:8080
      preferences : attrset → JSON for /api/v2/app/setPreferences
      categories  : attrset name → save_path
  */
  mkQbtPushService =
    {
      baseUrl,
      preferences ? { },
      categories ? { },
    }:
    let
      prefsFile = pkgs.writeText "qbt-preferences.json" (builtins.toJSON preferences);
      categoriesFile = pkgs.writeText "qbt-categories.json" (builtins.toJSON categories);
    in
    {
      systemd.services.qbittorrent-config = {
        description = "Push qBittorrent preferences + categories";
        after = [ "qbittorrent.service" ];
        requires = [ "qbittorrent.service" ];
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

          ${self.waitForApiScript {
            url = "${baseUrl}/api/v2/app/version";
          }}

          # Subnet bypass means we don't need cookie auth from 127.0.0.1.
          # (If bypass is disabled, this will fail with 403; that's a config error.)

          ${lib.optionalString (preferences != { }) ''
            echo "Pushing qBittorrent preferences"
            json=$(cat ${prefsFile})
            curl -fsS -X POST "${baseUrl}/api/v2/app/setPreferences" \
              --data-urlencode "json=$json" >/dev/null
          ''}

          ${lib.optionalString (categories != { }) ''
            echo "Reconciling qBittorrent categories"
            current=$(curl -fsS "${baseUrl}/api/v2/torrents/categories")
            desired=$(cat ${categoriesFile})

            # Add/update each desired category
            for name in $(jq -r 'keys[]' <<< "$desired"); do
              save_path=$(jq -r --arg n "$name" '.[$n]' <<< "$desired")
              if jq -e --arg n "$name" '.[$n]' <<< "$current" >/dev/null; then
                # Edit existing
                curl -fsS -X POST "${baseUrl}/api/v2/torrents/editCategory" \
                  --data-urlencode "category=$name" \
                  --data-urlencode "savePath=$save_path" >/dev/null
              else
                curl -fsS -X POST "${baseUrl}/api/v2/torrents/createCategory" \
                  --data-urlencode "category=$name" \
                  --data-urlencode "savePath=$save_path" >/dev/null
              fi
            done

            # Delete extras
            for name in $(jq -r 'keys[]' <<< "$current"); do
              if ! jq -e --arg n "$name" '.[$n]' <<< "$desired" >/dev/null; then
                curl -fsS -X POST "${baseUrl}/api/v2/torrents/removeCategories" \
                  --data-urlencode "categories=$name" >/dev/null
              fi
            done
          ''}
        '';
      };
    };

  /**
    Bash snippet that computes a PBKDF2-SHA512 hash of a plaintext password
    file and sed-replaces qBittorrent.conf's Password_PBKDF2 line.

    Format matches qBittorrent's expectations
    (src/base/utils/password.cpp:88-111):
      - 16 random bytes salt
      - 100 000 iterations PBKDF2-HMAC-SHA512
      - 64-byte output
      - Stored as "<base64-salt>:<base64-key>" wrapped in @ByteArray(...).

    Used as one of the systemd ExecStartPre's of the qbittorrent service.
    Args:
      plaintextFile  : sops-resolved file with plaintext password
      configFile     : path to qBittorrent.conf
  */
  qbtPasswordHashScript =
    {
      plaintextFile,
      configFile,
    }:
    pkgs.writeShellApplication {
      name = "qbt-password-hash";
      runtimeInputs = [
        pkgs.openssl
        pkgs.coreutils
        pkgs.gnused
      ];
      text = ''
        set -euo pipefail

        if [ ! -r "${plaintextFile}" ]; then
          echo "qBittorrent plaintext password file not readable: ${plaintextFile}" >&2
          exit 1
        fi

        if [ ! -f "${configFile}" ]; then
          echo "qBittorrent.conf not yet present: ${configFile}; nothing to do." >&2
          exit 0
        fi

        password=$(tr -d '\n' < "${plaintextFile}")
        salt_hex=$(openssl rand -hex 16)
        salt_bin=$(printf '%s' "$salt_hex" | xxd -r -p)
        salt_b64=$(printf '%s' "$salt_bin" | base64 -w0)

        key_hex=$(openssl kdf \
          -keylen 64 \
          -kdfopt digest:SHA512 \
          -kdfopt "pass:$password" \
          -kdfopt "hexsalt:$salt_hex" \
          -kdfopt iter:100000 \
          PBKDF2 | tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '\n')
        key_bin=$(printf '%s' "$key_hex" | xxd -r -p)
        key_b64=$(printf '%s' "$key_bin" | base64 -w0)

        hash="@ByteArray($salt_b64:$key_b64)"

        # Replace existing Password_PBKDF2 line, or append under [Preferences]
        if grep -q '^WebUI\\Password_PBKDF2=' "${configFile}"; then
          sed -i "s|^WebUI\\\\Password_PBKDF2=.*|WebUI\\\\Password_PBKDF2=$hash|" "${configFile}"
        else
          # Insert after [Preferences] header. If header doesn't exist, append.
          if grep -q '^\[Preferences\]' "${configFile}"; then
            sed -i "/^\[Preferences\]/a WebUI\\\\Password_PBKDF2=$hash" "${configFile}"
          else
            printf '\n[Preferences]\nWebUI\\\\Password_PBKDF2=%s\n' "$hash" >> "${configFile}"
          fi
        fi
      '';
    };

})
