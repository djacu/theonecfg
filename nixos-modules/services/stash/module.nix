{ config, lib, pkgs, ... }:
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) bool listOf int str submodule;

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
