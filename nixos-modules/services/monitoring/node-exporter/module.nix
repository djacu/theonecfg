{
  config,
  lib,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    mkOption
    ;

  inherit (lib.types)
    int
    ;

  cfg = config.theonecfg.services.monitoring.node-exporter;

in
{
  options.theonecfg.services.monitoring.node-exporter = {
    enable = mkEnableOption "Prometheus node_exporter (host metrics)";
    port = mkOption {
      type = int;
      default = 9100;
    };
  };

  config = mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      port = cfg.port;
      enabledCollectors = [
        "systemd"
        "processes"
      ];
      openFirewall = false;
    };
  };
}
