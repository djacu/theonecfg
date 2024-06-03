{ lib, config, ... }:
let
  cfg = config.theonecfg.basicNetwork;
in
{
  options.theonecfg.basicNetwork.enable = lib.mkEnableOption "basic network setup";

  config = lib.mkIf cfg.enable {
    networking.useDHCP = lib.mkDefault true;
    networking.networkmanager.enable = true;
  };
}
