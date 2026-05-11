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

  cfg = config.theonecfg.services.glances;

in
{
  options.theonecfg.services.glances = {
    enable = mkEnableOption "Glances system metrics + REST API";
    domain = mkOption {
      type = str;
      default = "glances.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 61208;
      description = "Glances web/REST API port; bound to loopback. Caddy proxies from there.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.glances = {
        enable = true;
        port = cfg.port;
        # `-w` selects the web/REST API server (otherwise glances starts
        # in TUI mode, which is meaningless under systemd); `--bind
        # 127.0.0.1` locks the listener to loopback so it stays off the
        # LAN even if openFirewall ever flips on. The Homepage dashboard's
        # `glances` widget reaches the API on this loopback URL.
        extraArgs = [
          "-w"
          "--bind"
          "127.0.0.1"
        ];
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
