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

  cfg = config.theonecfg.services.monitoring.prometheus;
  nodeCfg = config.theonecfg.services.monitoring.node-exporter;
  zfsCfg = config.theonecfg.services.monitoring.zfs-exporter;

  scrapeJob = name: target: {
    job_name = name;
    static_configs = [ { targets = [ target ]; } ];
  };

in
{
  options.theonecfg.services.monitoring.prometheus = {
    enable = mkEnableOption "Prometheus (TSDB + scraper)";
    domain = mkOption {
      type = str;
      default = "prometheus.${config.theonecfg.networking.lanDomain}";
    };
    port = mkOption {
      type = int;
      default = 9090;
    };
    retention = mkOption {
      type = str;
      default = "90d";
      description = "TSDB retention period.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = cfg.port;
        retentionTime = cfg.retention;

        scrapeConfigs =
          (lib.optional nodeCfg.enable (scrapeJob "node" "127.0.0.1:${toString nodeCfg.port}"))
          ++ (lib.optional zfsCfg.enable (scrapeJob "zfs" "127.0.0.1:${toString zfsCfg.port}"))
          ++ [
            (scrapeJob "prometheus" "127.0.0.1:${toString cfg.port}")
          ];
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
