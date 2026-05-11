{ config, lib, pkgs, ... }:
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) bool listOf int nullOr str submodule;

  cfg = config.theonecfg.services.stash;

  stashApikeySplice = pkgs.writeShellApplication {
    name = "stash-apikey-splice";
    runtimeInputs = [ pkgs.coreutils pkgs.yq-go ];
    text = ''

      config="${cfg.dataDir}/config.yml"

      if [ ! -f "$config" ]; then
        echo "stash config.yml not found at $config" >&2
        exit 1
      fi

      ${lib.optionalString (cfg.apiKeyFile != null) ''
        if [ ! -r "${cfg.apiKeyFile}" ]; then
          echo "stash apikey file not readable: ${cfg.apiKeyFile}" >&2
          exit 1
        fi
        NEW_KEY="$(tr -d '\r\n' < "${cfg.apiKeyFile}")" \
          yq -i '.api_key = strenv(NEW_KEY)' "$config"
      ''}

      ${lib.concatMapStringsSep "\n" (b: ''
        if [ ! -r "${b.apiKeyFile}" ]; then
          echo "stash apikey file not readable: ${b.apiKeyFile} (stash_boxes[${b.name}])" >&2
          exit 1
        fi
        NEW_KEY="$(tr -d '\r\n' < "${b.apiKeyFile}")" \
          yq -i \
          '(.stash_boxes[] | select(.name == "${b.name}") | .apikey) = strenv(NEW_KEY)' \
          "$config"
      '') cfg.stashBoxes}

      chown stash:media "$config"
      chmod 0600 "$config"
    '';
  };

  identifyBody = builtins.toJSON {
    query = "mutation Identify($sources: [IdentifySourceInput!]!) { metadataIdentify(input: { sources: $sources }) }";
    variables.sources = map (b: {
      source = { stash_box_endpoint = b.endpoint; };
    }) cfg.stashBoxes;
  };

  simpleBody = mutation: builtins.toJSON {
    query = "mutation { ${mutation} }";
  };

  scanBody     = simpleBody "metadataScan(input: {})";
  autoTagBody  = simpleBody "metadataAutoTag(input: {})";
  generateBody = simpleBody "metadataGenerate(input: {})";
  cleanBody    = simpleBody "metadataClean(input: { dryRun: false })";

  stashMaintenance = pkgs.writeShellApplication {
    name = "stash-maintenance";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    # SC2016: the JSON bodies contain `$sources` as a GraphQL variable
    # reference, not a bash variable. Keeping them in single quotes so
    # bash passes them literally is intentional.
    excludeShellChecks = [ "SC2016" ];
    text = ''
      if [ ! -r "${toString cfg.apiKeyFile}" ]; then
        echo "stash API key not readable: ${toString cfg.apiKeyFile}" >&2
        exit 1
      fi
      apikey="$(tr -d '\r\n' < "${toString cfg.apiKeyFile}")"
      endpoint="http://127.0.0.1:${toString cfg.port}/graphql"

      post() {
        local label="$1" body="$2" response
        echo "Triggering: $label"
        response="$(curl -fsS --max-time 30 -X POST "$endpoint" \
          -H "Content-Type: application/json" \
          -H "ApiKey: $apikey" \
          -d "$body")"
        if jq -e '.errors' <<< "$response" >/dev/null 2>&1; then
          echo "  GraphQL error: $response" >&2
          return 1
        fi
        echo "  Job ID: $(jq -r '.data | to_entries[0].value' <<< "$response")"
      }

      post "scan"     '${scanBody}'
      post "identify" '${identifyBody}'
      post "autotag"  '${autoTagBody}'
      post "generate" '${generateBody}'
      post "clean"    '${cleanBody}'

      echo "All maintenance tasks queued. Stash executes them serially via its internal task queue."
    '';
  };

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
    apiKeyFile = mkOption {
      type = nullOr str;
      default = null;
      description = ''
        Path to a file containing Stash's own API key. When set, the key is
        spliced into config.yml on every restart, overriding Stash's
        auto-generated key. Used by other services (e.g. Stasharr) to
        authenticate against Stash's REST/GraphQL API.
      '';
    };
    scheduledMaintenance = {
      enable = mkEnableOption "Daily Stash library maintenance (scan + identify + auto tag + generate + clean)";
      schedule = mkOption {
        type = str;
        default = "*-*-* 03:00:00";
        description = ''
          systemd OnCalendar expression for when the maintenance pipeline fires.
          Default is 03:00 local time, daily.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.stash = {
        enable = true;
        dataDir = cfg.dataDir;
        user = "stash";
        group = "media";
        mutableSettings = true;
        # Upstream's setup script unconditionally string-interpolates
        # `${cfg.passwordFile}` into bash, so passwordFile=null (the
        # documented "no local auth" default) crashes Nix evaluation.
        # Set username + empty-content passwordFile to satisfy the
        # assertion AND the interpolation; the renderer's
        # `with(select($password != ""))` guard skips writing the
        # password field, so config.yml ends up with no usable local
        # login. Caddy + kanidm forward_auth gates access instead.
        username = "admin";
        passwordFile = pkgs.writeText "stash-no-local-auth" "";
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
        }
        // lib.optionalAttrs (cfg.apiKeyFile != null) {
          api_key = "@APIKEY_STASH@";
        };
      };

      users.users.stash.extraGroups = [ "media" ];

      # Upstream's tmpfiles rule for dataDir is type `d` (create-with-
      # owner), which only sets ownership on creation. When dataDir is
      # a ZFS dataset created out-of-band (root-owned by `zfs create`),
      # tmpfiles sees an existing dir and skips ownership; Stash's
      # ExecStartPre then can't write to it. `z` adjusts ownership on
      # every switch.
      systemd.tmpfiles.rules = [
        "z ${cfg.dataDir} 0755 stash media - -"
      ];

      systemd.services.stash.serviceConfig.ExecStartPre = lib.mkAfter [
        "+${stashApikeySplice}/bin/stash-apikey-splice"
      ];

      systemd.services.stash.unitConfig.RequiresMountsFor =
        map (s: s.path) cfg.stashes;

      sops.secrets = {
        "stash/jwt-secret".owner = "stash";
        "stash/session-store-key".owner = "stash";
      };

      assertions = [
        {
          assertion = !cfg.scheduledMaintenance.enable || cfg.apiKeyFile != null;
          message = "theonecfg.services.stash.scheduledMaintenance.enable requires apiKeyFile to be set (Stash's GraphQL mutations refuse requests without an ApiKey header).";
        }
      ];

      systemd.timers.stash-maintenance = mkIf cfg.scheduledMaintenance.enable {
        description = "Daily Stash library maintenance";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.scheduledMaintenance.schedule;
          Persistent = true;
        };
      };

      systemd.services.stash-maintenance = mkIf cfg.scheduledMaintenance.enable {
        description = "Stash library maintenance: scan + identify + auto tag + generate + clean";
        after = [ "stash.service" ];
        requires = [ "stash.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${stashMaintenance}/bin/stash-maintenance";
        };
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
