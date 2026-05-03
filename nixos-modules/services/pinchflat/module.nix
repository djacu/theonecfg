{
  config,
  lib,
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

  cfg = config.theonecfg.services.pinchflat;

in
{
  options.theonecfg.services.pinchflat = {
    enable = mkEnableOption "Pinchflat (YouTube archiver)";
    domain = mkOption {
      type = str;
      default = "pinchflat.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 8945;
    };
    mediaDir = mkOption {
      type = str;
      default = "/var/lib/pinchflat/media";
      description = "Where Pinchflat archives downloaded videos.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.pinchflat = {
        enable = true;
        mediaDir = cfg.mediaDir;
      };

      # Pinchflat uses DynamicUser; StateDirectory creates /var/lib/pinchflat
      # automatically. On hosts that roll back root state (impermanence),
      # the host's impermanence config must list /var/lib/pinchflat among
      # the persisted directories — see nixos-configurations/<host>/impermanence.nix.

      systemd.tmpfiles.rules = [
        "d ${cfg.mediaDir} 0775 root root - -"
      ];

      systemd.services.pinchflat.unitConfig.RequiresMountsFor = [
        cfg.mediaDir
      ];
    }

    (mkIf config.theonecfg.services.caddy.enable {
      services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
        import forward_auth_kanidm
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';
    })
  ]);
}
