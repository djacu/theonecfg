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

    If `apiKeyFile` is given, the probe sends an `X-Api-Key:` header read
    from that file at runtime. Required for *arr `/api/v3/system/status`,
    which 401s without a key even when `auth.required = "DisabledForLocalAddresses"`
    (that setting only relaxes UI login, not the REST API).

    Returns a Bash snippet usable inside `script` or `preStart`.
  */
  waitForApiScript =
    {
      url,
      timeout ? 300,
      apiKeyFile ? null,
    }:
    ''
      ${lib.optionalString (apiKeyFile != null) ''
        wait_apikey="$(tr -d '\n' < "${apiKeyFile}")"
      ''}
      end=$((SECONDS+${toString timeout}))
      until ${pkgs.curl}/bin/curl -fsSk --max-time 5 ${
        lib.optionalString (apiKeyFile != null) ''-H "X-Api-Key: $wait_apikey"''
      } "${url}" >/dev/null 2>&1; do
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

    On HTTP errors (4xx/5xx) the wrapper prints the response body to stderr
    before exiting non-zero. *arr APIs return validator messages in 400
    bodies, which curl's -f flag would otherwise silently discard.
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
        body=$(mktemp)
        trap 'rm -f "$body"' EXIT
        http_code=$(curl -sS \
          -H "X-Api-Key: $apikey" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json" \
          -o "$body" \
          -w "%{http_code}" \
          "$@")
        if [ "$http_code" -ge 400 ]; then
          echo "HTTP $http_code from $*" >&2
          cat "$body" >&2
          echo >&2
          exit 22
        fi
        cat "$body"
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
      noUpdate    : if true, skip PUT on comparator-match — use for endpoints
                    that only expose POST/GET/DELETE (no PUT), notably
                    *arr's /api/v3/rootfolder. Treats the resource as
                    identity-by-comparator: matching key = nothing to do.
                    Drift in non-comparator fields can't be reconciled,
                    which is fine for rootfolder (only field is `path`).

    Behavior at runtime:
      1. Wait for ${baseUrl}${endpoint} to respond.
      2. GET current state.
      3. For each desired item: if comparator value matches an existing
         item, PUT (or skip if noUpdate); else POST.
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
      noUpdate ? false,
      tagsSourceUrl ? null,
      # Optional list of `{ url, apiKeyFile? }` API endpoints to wait on
      # *before* the reconcile loop runs, in addition to the parent
      # baseUrl+endpoint. Use this when the target API will perform its
      # own connection tests against downstream services as part of the
      # PUT/POST — Prowlarr's /api/v1/applications validates each *arr's
      # /api/v3/system/status before accepting an Application entry, so
      # all four *arrs must be listening, not just Prowlarr itself.
      # `systemd.after` only guarantees the units have started, not that
      # their HTTP servers have bound their ports.
      extraApiWaits ? [ ],
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
            # Poll the target endpoint directly — works for /api/v1/* (Prowlarr)
            # and /api/v3/* (*arr) without needing a separate version param.
            url = "${baseUrl}${endpoint}";
            inherit apiKeyFile;
          }}

          ${lib.concatMapStrings (
            w:
            self.waitForApiScript {
              url = w.url;
              apiKeyFile = w.apiKeyFile or null;
            }
          ) extraApiWaits}

          curl_cmd=curl-${name}

          current=$($curl_cmd "${baseUrl}${endpoint}")

          # Replace any `_<fieldName>File` markers on each item with a runtime
          # injection: read the file's contents and add {name, value} into
          # `fields`, then drop the marker. Lets callers reference sops paths
          # without baking secrets into the Nix store.
          desired=$(jq '${finalize}' < ${itemsFile} | jq -c '.[]' | while read -r item; do
            for marker in $(jq -r 'keys_unsorted[] | select(test("^_.*File$"))' <<< "$item"); do
              fname="''${marker#_}"
              fname="''${fname%File}"
              fpath=$(jq -r --arg m "$marker" '.[$m]' <<< "$item")
              fval=$(tr -d '\n' < "$fpath")
              item=$(jq -c --arg n "$fname" --arg v "$fval" --arg m "$marker" \
                '.fields = (.fields // []) + [{name: $n, value: $v}] | del(.[$m])' <<< "$item")
            done
            printf '%s\n' "$item"
          done)

          ${lib.optionalString (tagsSourceUrl != null) ''
            # Resolve tag labels → int ids. Prowlarr (and *arr) /tag endpoints
            # return [{id, label}, ...]; the wire format on POST expects
            # tags = [<int>, ...]. Author declarations carry tags = ["anime"];
            # we look up the id and substitute. Unknown labels error out
            # loudly — the prowlarr-tags one-shot is responsible for ensuring
            # every label we reference exists.
            tag_map=$($curl_cmd "${tagsSourceUrl}" | jq -c 'map({(.label): .id}) | add // {}')
            desired=$(echo "$desired" | while read -r item; do
              [ -z "$item" ] && continue
              jq -c --argjson m "$tag_map" '
                if (.tags // []) | length > 0 then
                  .tags = [.tags[] | if type == "string" then ($m[.] // error("Unknown tag: \(.)")) else . end]
                else .
                end
              ' <<< "$item"
            done)
          ''}

          # Collect existing items by comparator → id
          declare -A existing_ids
          while IFS=$'\t' read -r key id; do
            [ -n "$key" ] && existing_ids["$key"]="$id"
          done < <(jq -r ".[] | \"\(.${comparator})\\t\(.id)\"" <<< "$current")

          # Track failures so one broken item (e.g. an indexer Prowlarr can't
          # reach) doesn't tank the whole reconciliation. mkSecureCurl prints
          # the response body on each 4xx/5xx; the unit still ends non-zero
          # if any item failed so systemd surfaces it.
          fails=0

          # Collect desired keys for later diff (delete pass)
          declare -A desired_keys
          while read -r item; do
            key=$(jq -r ".${comparator}" <<< "$item")
            desired_keys["$key"]=1

            if [ -n "''${existing_ids[$key]:-}" ]; then
              id="''${existing_ids[$key]}"
              ${
                if noUpdate then
                  ''
                    echo "SKIP ${endpoint}/$id ($key) — already exists"
                  ''
                else
                  ''
                    payload=$(jq -c --argjson id "$id" '. + { id: $id }' <<< "$item")
                    echo "PUT ${endpoint}/$id ($key)"
                    if ! $curl_cmd -X PUT -d "$payload" "${baseUrl}${endpoint}/$id" >/dev/null; then
                      echo "FAIL PUT ${endpoint}/$id ($key)" >&2
                      fails=$((fails+1))
                    fi
                  ''
              }
            else
              echo "POST ${endpoint} ($key)"
              if ! $curl_cmd -X POST -d "$item" "${baseUrl}${endpoint}" >/dev/null; then
                echo "FAIL POST ${endpoint} ($key)" >&2
                fails=$((fails+1))
              fi
            fi
          done <<< "$desired"

          # Delete pass — remove anything in current not in desired
          while IFS=$'\t' read -r key id; do
            if [ -n "$key" ] && [ -z "''${desired_keys[$key]:-}" ]; then
              echo "DELETE ${endpoint}/$id ($key)"
              if ! $curl_cmd -X DELETE "${baseUrl}${endpoint}/$id" >/dev/null; then
                echo "FAIL DELETE ${endpoint}/$id ($key)" >&2
                fails=$((fails+1))
              fi
            fi
          done < <(jq -r ".[] | \"\(.${comparator})\\t\(.id)\"" <<< "$current")

          if [ "$fails" -gt 0 ]; then
            echo "$fails item(s) failed; see FAIL lines above" >&2
            exit 22
          fi
        '';
      };
    };

  /**
    Build a single qBittorrent download-client entry shaped for *arr's
    /api/v3/downloadclient or Prowlarr's /api/v1/downloadclient. Returns
    an attrset matching `arrTypes.downloadClientType`.

    Sonarr v4 / Sonarr-anime / Whisparr (Sonarr-v3 fork) and Radarr share
    most fields but differ on the category + priority field names:
      - "tv"       : tvCategory, recentTvPriority, olderTvPriority
      - "movie"    : movieCategory, recentMoviePriority, olderMoviePriority
      - "prowlarr" : category (no per-age priority — Prowlarr's
                     download-client schema only carries a single
                     `category` field for manually-grabbed releases)
    Verified against each app's QBittorrentSettings.cs on the develop branch.

    `username` / `password` are empty: qBittorrent's
    AuthSubnetWhitelist=127.0.0.1/32 lets localhost connections in without
    auth, and *arr / Prowlarr bind to / connect from 127.0.0.1.

    Args:
      port      : qBittorrent webUI port (e.g. 8080)
      category  : qBittorrent category name (matches autoCategories)
      variant   : "tv" (default), "movie", or "prowlarr"
  */
  mkQbtDownloadClient =
    {
      port,
      category,
      variant ? "tv",
    }:
    let
      fieldNames =
        if variant == "movie" then
          {
            cat = "movieCategory";
            priorityFields = [
              "recentMoviePriority"
              "olderMoviePriority"
            ];
          }
        else if variant == "prowlarr" then
          {
            cat = "category";
            # Prowlarr's qBittorrent download client expects a single
            # `priority` field (download priority within qBittorrent),
            # NOT the *arr's recent/older split. Confirmed against
            # /api/v1/downloadclient/schema; omitting it triggers a
            # null-ref on the test ("Object reference not set to an
            # instance of an object").
            priorityFields = [ "priority" ];
          }
        else
          {
            cat = "tvCategory";
            priorityFields = [
              "recentTvPriority"
              "olderTvPriority"
            ];
          };
    in
    {
      name = "qBittorrent";
      enable = true;
      priority = 1;
      implementation = "QBittorrent";
      implementationName = "qBittorrent";
      configContract = "QBittorrentSettings";
      tags = [ ];
    }
    # `removeCompletedDownloads` / `removeFailedDownloads` are *arr-only
    # behaviors (the *arrs manage import + cleanup). Prowlarr's qBittorrent
    # client schema doesn't have them — sending them produces no test
    # failure but is noise.
    // lib.optionalAttrs (variant != "prowlarr") {
      removeCompletedDownloads = true;
      removeFailedDownloads = true;
    }
    # `protocol` and `categories` are required by Prowlarr's
    # /api/v1/downloadclient schema; missing `protocol` triggers a
    # null-ref in the test path ("Object reference not set to an
    # instance of an object"). The *arrs derive protocol from
    # implementation and don't expose it as a payload field.
    // lib.optionalAttrs (variant == "prowlarr") {
      protocol = "torrent";
      categories = [ ];
    }
    // {
      fields =
        [
          {
            name = "host";
            value = "127.0.0.1";
          }
          {
            name = "port";
            value = port;
          }
          {
            name = "useSsl";
            value = false;
          }
          {
            name = "urlBase";
            value = "";
          }
          {
            name = "username";
            value = "";
          }
          {
            name = "password";
            value = "";
          }
          {
            name = fieldNames.cat;
            value = category;
          }
        ]
        ++ map (n: {
          name = n;
          value = 0;
        }) fieldNames.priorityFields
        ++ [
          {
            name = "initialState";
            value = 0;
          }
        {
          name = "sequentialOrder";
          value = false;
        }
        {
          name = "firstAndLast";
          value = false;
        }
        {
          name = "contentLayout";
          value = 0;
        }
      ];
    };

  /**
    Build a single Cardigann indexer entry for Prowlarr's /api/v1/indexer.
    Returns an attrset matching `arrTypes.indexerType`.

    All Cardigann indexers in Prowlarr share the same baseSettings/
    torrentBaseSettings shape — verified against /api/v1/indexer/schema.
    The `definitionFile` field carries the indexer slug (e.g. "eztv",
    "nyaasi", "kickasstorrents-ws"); Prowlarr looks up the matching
    YAML definition from its bundled `Prowlarr/Indexers` repo.

    `seederThreshold` (default 5) sets `torrentBaseSettings.appMinimumSeeders`
    — filters fake-seed spam on public trackers. Pass null to omit.

    Use `extraFields` for indexer-specific options (Nyaa's `cat-id`,
    `sonarr_compatibility`, etc.). Each entry is a `{name, value}` pair.

    Args:
      name            : display name (also the comparator)
      definitionFile  : Prowlarr/Indexers YAML slug
      tags            : list of label strings (resolved to int IDs at runtime
                        by the consuming one-shot)
      seederThreshold : optional minimum-seeders filter (default 5)
      extraFields     : list of {name, value} pairs to append to fields
      enable          : default true
      priority        : default 25 (Prowlarr's default)
  */
  mkCardigannIndexer =
    {
      name,
      definitionFile,
      tags ? [ ],
      seederThreshold ? 5,
      extraFields ? [ ],
      enable ? true,
      priority ? 25,
      # Stock Prowlarr provisions a "Default" app profile at id=1 with
      # RSS+Automatic+Interactive all on. POST /api/v1/indexer rejects
      # appProfileId=0 (FluentValidation), so we set 1 explicitly.
      appProfileId ? 1,
    }:
    {
      inherit
        name
        tags
        enable
        priority
        appProfileId
        ;
      implementation = "Cardigann";
      implementationName = "Cardigann";
      configContract = "CardigannSettings";
      protocol = "torrent";
      fields =
        [
          {
            name = "definitionFile";
            value = definitionFile;
          }
        ]
        ++ lib.optional (seederThreshold != null) {
          name = "torrentBaseSettings.appMinimumSeeders";
          value = seederThreshold;
        }
        ++ extraFields;
    };

  /**
    Cardigann indexer with sops-injected username + password. Emits
    `_usernameFile` and `_passwordFile` markers; the consuming one-shot
    (mkArrApiPushService) reads each file at runtime and adds
    `{name: "username"|"password", value: <file contents>}` into `fields`.

    Default `seederThreshold = null`: private trackers report honest
    seeder counts and Empornium-style trackers may have low-seeder
    legitimate releases worth grabbing.

    Args:
      name             : display name (comparator)
      definitionFile   : Prowlarr/Indexers YAML slug
      usernameFile     : sops-resolved path holding the tracker username
      passwordFile     : sops-resolved path holding the tracker password
      tags             : labels (resolved to ids at runtime)
      seederThreshold  : optional minimum-seeders filter (default null)
      extraFields      : extra {name, value} pairs (e.g. `freeleech` for Empornium)
  */
  mkCardigannIndexerWithCreds =
    {
      name,
      definitionFile,
      usernameFile,
      passwordFile,
      tags ? [ ],
      seederThreshold ? null,
      extraFields ? [ ],
      enable ? true,
      priority ? 25,
      appProfileId ? 1,
    }:
    (self.mkCardigannIndexer {
      inherit
        name
        definitionFile
        tags
        seederThreshold
        extraFields
        enable
        priority
        appProfileId
        ;
    })
    // {
      _usernameFile = usernameFile;
      _passwordFile = passwordFile;
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

          # Poll /Startup/Configuration directly. Jellyfin's HTTP server
          # (and /System/Info/Public) come up several seconds before the
          # StartupController is ready; using the actual endpoint we'll
          # POST to as the readiness probe avoids 503s on the first POST.
          # 200 → wizard pending, proceed. 401 → wizard already complete,
          # short-circuit (idempotency). Any other code → keep polling.
          end=$((SECONDS+300))
          status=0
          while true; do
            status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${baseUrl}/Startup/Configuration" || echo 0)
            case "$status" in
              200|401) break ;;
            esac
            if [ $SECONDS -ge $end ]; then
              echo "Timeout waiting for ${baseUrl}/Startup/Configuration (last status: $status)" >&2
              exit 1
            fi
            sleep 2
          done

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
          # GET first — Jellyfin's POST handler calls _userManager.Users.First()
          # which throws on an empty user list. The default user is seeded
          # lazily inside GET /Startup/User via InitializeAsync(); the web
          # wizard does GET on view-show, POST on submit, which is why the UI
          # works but a POST-only script fails. Upstream issue:
          # https://github.com/jellyfin/jellyfin/issues/16720
          curl -fsS "${baseUrl}/Startup/User" >/dev/null

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

          # Add missing — use `while read -r` to preserve whitespace in
          # library names ("TV Shows", "Home Videos", etc.). `for in $list`
          # would word-split on space and turn "TV Shows" into two libraries.
          while IFS= read -r name; do
            [ -z "$name" ] && continue
            if ! grep -qx "$name" <<< "$existing_names"; then
              echo "Adding Jellyfin library: $name"
              entry=$(jq -c --arg n "$name" '.[$n]' <<< "$desired")
              ctype=$(jq -r '.type' <<< "$entry")
              # Build query string with ?paths= per path
              query="name=$(jq -rn --arg s "$name" '$s | @uri')&collectionType=$ctype&refreshLibrary=false"
              while IFS= read -r p; do
                [ -z "$p" ] && continue
                query="$query&paths=$(jq -rn --arg s "$p" '$s | @uri')"
              done < <(jq -r '.paths[]' <<< "$entry")

              opts=$(jq -c '.options // {}' <<< "$entry")
              curl -fsS -X POST "${baseUrl}/Library/VirtualFolders?$query" \
                "''${auth[@]}" \
                -H "Content-Type: application/json" \
                -d "$opts" >/dev/null
            fi
          done <<< "$desired_names"

          # Delete extras — same word-split concern.
          while IFS= read -r name; do
            [ -z "$name" ] && continue
            if ! grep -qx "$name" <<< "$desired_names"; then
              echo "Removing Jellyfin library: $name"
              curl -fsS -X DELETE "${baseUrl}/Library/VirtualFolders?name=$(jq -rn --arg s "$name" '$s | @uri')" \
                "''${auth[@]}" >/dev/null
            fi
          done <<< "$existing_names"
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

            # Add/update each desired category. qBittorrent 5.1.4's
            # /api/v2/torrents/editCategory returns 409 when the new options
            # already equal the stored ones (sessionimpl.cpp::editCategory),
            # so skip the edit call when savePath already matches — the API
            # treats no-op edits as failures.
            for name in $(jq -r 'keys[]' <<< "$desired"); do
              save_path=$(jq -r --arg n "$name" '.[$n]' <<< "$desired")
              if jq -e --arg n "$name" '.[$n]' <<< "$current" >/dev/null; then
                current_save_path=$(jq -r --arg n "$name" '.[$n].savePath' <<< "$current")
                if [ "$current_save_path" != "$save_path" ]; then
                  curl -fsS -X POST "${baseUrl}/api/v2/torrents/editCategory" \
                    --data-urlencode "category=$name" \
                    --data-urlencode "savePath=$save_path" >/dev/null
                fi
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
        pkgs.tinyxxd
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

        # Pipe the raw binary straight from xxd into base64 instead of
        # capturing it in a shell variable first. bash's $(...) command
        # substitution strips embedded NUL bytes (with a "command
        # substitution: ignored null byte in input" warning), which would
        # corrupt the 16-byte salt and 64-byte key — qBittorrent's stored
        # PBKDF2 line would then have base64 decoding to the wrong bytes
        # and password login would silently always fail.
        salt_b64=$(printf '%s' "$salt_hex" | xxd -r -p | base64 -w0)

        key_hex=$(openssl kdf \
          -keylen 64 \
          -kdfopt digest:SHA512 \
          -kdfopt "pass:$password" \
          -kdfopt "hexsalt:$salt_hex" \
          -kdfopt iter:100000 \
          PBKDF2 | tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '\n')
        key_b64=$(printf '%s' "$key_hex" | xxd -r -p | base64 -w0)

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
