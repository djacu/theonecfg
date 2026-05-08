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

  cfg = config.theonecfg.services.monitoring.smartctl-exporter;

in
{
  options.theonecfg.services.monitoring.smartctl-exporter = {
    enable = mkEnableOption ''
      Prometheus smartctl_exporter — exposes per-drive SMART metrics
      including SAS environmental-page temperatures, which Scrutiny's
      collector (as of 0.9.2) does not parse for SCSI/SAS drives. The
      relevant Scrutiny PR (AnalogJ/scrutiny#816) was abandoned upstream;
      this exporter is the workaround so SAS drive temps land in
      Prometheus and Grafana.
    '';
    port = mkOption {
      type = int;
      default = 9633;
    };
  };

  config = mkIf cfg.enable {
    services.prometheus.exporters.smartctl = {
      enable = true;
      port = cfg.port;
      openFirewall = false;
    };
  };
}
