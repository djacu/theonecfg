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
    # Opt out of Alloy's anonymous usage reporting to stats.grafana.org;
    # otherwise the daemon retries forever when the endpoint is blocked
    # (e.g. by an upstream DNS filter), spamming the journal.
    services.alloy.extraFlags = [ "--disable-reporting" ];

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
        forward_to    = [loki.process.level.receiver]
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

      // Extract a real `level` label from message bodies. Two formats
      // cover most services here: Go logfmt (`level=info`) and
      // Serilog/AdGuard/celery (`[Info]`, `[error]`, `[INFO]`). Lines
      // without a recognized level word (HTTP access logs, bare redis
      // text) end up `level=unlabeled` so the dashboard's level filter
      // never silently hides them.
      loki.process "level" {
        forward_to = [loki.write.default.receiver]

        // Drop two known-noise patterns from Loki's own logs before
        // they're indexed: "failed mapping AST" fires on every query
        // cancellation (each dashboard interaction generates these),
        // and "could not determine query overlaps" is transient
        // schema-config bookkeeping. Both are warn-level so they slip
        // past the dashboard's level filter; dropping at ingestion
        // keeps Loki at default `info` (full operational visibility)
        // without polluting the dashboard. Other Loki warn/error lines
        // (real ingester problems, slow queries) flow through.
        stage.match {
          selector            = "{unit=\"loki.service\"} |~ \"(failed mapping AST|could not determine query overlaps)\""
          action              = "drop"
          drop_counter_reason = "loki_self_noise"
        }

        // Default; the regex below overwrites on a successful match.
        stage.template {
          source   = "level"
          template = "unlabeled"
        }

        stage.regex {
          expression = "(?:level=|\\[)(?P<level>(?i:fatal|crit|critical|err|error|wrn|warn|warning|inf|info|notice|dbg|debug|trace))(?:\\b|\\])"
        }

        // Lowercase so the if-chain compares only lowercase variants.
        stage.template {
          source   = "level"
          template = "{{ ToLower .Value }}"
        }

        // Normalize to {critical, error, warning, info, debug}.
        // Anything else (including the "unlabeled" default) passes through.
        stage.template {
          source   = "level"
          template = "{{ if or (eq .Value \"fatal\") (eq .Value \"crit\") (eq .Value \"critical\") }}critical{{ else if or (eq .Value \"err\") (eq .Value \"error\") }}error{{ else if or (eq .Value \"wrn\") (eq .Value \"warn\") (eq .Value \"warning\") }}warning{{ else if or (eq .Value \"inf\") (eq .Value \"info\") (eq .Value \"notice\") }}info{{ else if or (eq .Value \"dbg\") (eq .Value \"debug\") (eq .Value \"trace\") }}debug{{ else }}{{ .Value }}{{ end }}"
        }

        stage.labels {
          values = { level = "" }
        }
      }
    '';
  };
}
