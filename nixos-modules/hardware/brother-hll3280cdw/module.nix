{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.hardware.brother-hll3280cdw;

in
{
  options.theonecfg.hardware.brother-hll3280cdw.enable =
    mkEnableOption "printing on Brother HL-L3280CDW";

  config = mkIf cfg.enable {

    services.printing.enable = true;
    services.printing.drivers = [
      pkgs.theonecfg.cups-brother-hll3280cdw
    ];
    # services.printing.logLevel = "debug";

  };
}
