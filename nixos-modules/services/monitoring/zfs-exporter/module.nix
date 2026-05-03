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

  cfg = config.theonecfg.services.monitoring.zfs-exporter;

in
{
  options.theonecfg.services.monitoring.zfs-exporter = {
    enable = mkEnableOption "Prometheus zfs_exporter (pool/dataset metrics)";
    port = mkOption {
      type = int;
      default = 9134;
    };
  };

  config = mkIf cfg.enable {
    services.prometheus.exporters.zfs = {
      enable = true;
      port = cfg.port;
      openFirewall = false;
    };
  };
}
