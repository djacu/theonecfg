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
    ;

  cfg = config.theonecfg.services.monitoring.alloy;
  lokiCfg = config.theonecfg.services.monitoring.loki;

in
{
  options.theonecfg.services.monitoring.alloy = {
    enable = mkEnableOption "Grafana Alloy (ship journald logs to Loki)";
  };

  config = mkIf cfg.enable {
    services.alloy.enable = true;

    # Alloy config in /etc/alloy/ so the daemon picks it up and reloads on
    # nixos-rebuild switch. River syntax. Reads journald (alloy is in
    # systemd-journal supplementary group via the upstream module) and ships
    # to the local Loki.
    environment.etc."alloy/config.alloy".text = ''
      loki.write "default" {
        endpoint {
          url = "http://127.0.0.1:${toString lokiCfg.port}/loki/api/v1/push"
        }
      }

      loki.source.journal "journal" {
        forward_to    = [loki.write.default.receiver]
        relabel_rules = loki.relabel.journal.rules
        labels        = {
          job  = "systemd-journal",
          host = "${config.networking.hostName}",
        }
      }

      loki.relabel "journal" {
        forward_to = []

        rule {
          source_labels = ["__journal__systemd_unit"]
          target_label  = "unit"
        }
      }
    '';
  };
}
