{
  config,
  lib,
  ...
}:
let

  inherit (lib.modules)
    mkDefault
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.networking.basic-network;

in
{
  options.theonecfg.networking.basic-network.enable = mkEnableOption "theonecfg basic network setup";

  config = mkIf cfg.enable {

    networking.useDHCP = mkDefault true;
    networking.networkmanager.enable = mkDefault true;

  };
}
