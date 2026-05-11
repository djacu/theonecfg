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

  cfg = config.theonecfg.services.monitoring.scrutiny;

in
{
  options.theonecfg.services.monitoring.scrutiny = {
    enable = mkEnableOption "Scrutiny (SMART monitoring with web UI)";
    domain = mkOption {
      type = str;
      default = "scrutiny.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      # Scrutiny upstream default is 8080, but qBittorrent's WebUI also
      # defaults to 8080 — pick a non-colliding port so both can coexist
      # on loopback.
      default = 8083;
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.scrutiny = {
        enable = true;
        collector.enable = true;
        settings = {
          web.listen.host = "127.0.0.1";
          web.listen.port = cfg.port;
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
