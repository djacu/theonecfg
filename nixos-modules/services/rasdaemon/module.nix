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

  cfg = config.theonecfg.services.rasdaemon;

in
{
  options.theonecfg.services.rasdaemon.enable =
    mkEnableOption "rasdaemon RAS/MCE logging with decoded hardware-error events";

  config = mkIf cfg.enable {
    hardware.rasdaemon = {
      enable = true;
      # Record events into the sqlite DB. Without this rasdaemon only
      # decodes to the journal; `ras-mc-ctl --summary` / `--errors`
      # (the decode + history we actually want) need the recorded DB.
      record = true;
    };
  };
}
