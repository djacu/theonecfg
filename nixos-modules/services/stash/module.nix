{ config, lib, ... }:
let
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.types) bool listOf int str submodule;

  cfg = config.theonecfg.services.stash;

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
