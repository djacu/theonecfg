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
    str
    ;

  cfg = config.theonecfg.services.monitoring.loki;

in
{
  options.theonecfg.services.monitoring.loki = {
    enable = mkEnableOption "Loki (log aggregation)";
    port = mkOption {
      type = int;
      default = 3100;
    };
    dataDir = mkOption {
      type = str;
      default = "/var/lib/loki";
    };
  };

  config = mkIf cfg.enable {
    services.loki = {
      enable = true;
      dataDir = cfg.dataDir;
      configuration = {
        auth_enabled = false;
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = cfg.port;
        };
        common = {
          path_prefix = cfg.dataDir;
          replication_factor = 1;
          ring.kvstore.store = "inmemory";
          ring.instance_addr = "127.0.0.1";
        };
        schema_config.configs = [
          {
            from = "2025-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
        storage_config = {
          tsdb_shipper = {
            active_index_directory = "${cfg.dataDir}/tsdb-index";
            cache_location = "${cfg.dataDir}/tsdb-cache";
          };
          filesystem.directory = "${cfg.dataDir}/chunks";
        };
        limits_config = {
          retention_period = "720h";
          allow_structured_metadata = true;
        };
        compactor = {
          working_directory = "${cfg.dataDir}/compactor";
          retention_enabled = true;
          delete_request_store = "filesystem";
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 loki loki - -"
    ];

    systemd.services.loki.unitConfig.RequiresMountsFor = [
      cfg.dataDir
    ];
  };
}
