{ lib, config, ... }:
let
  cfg = config.theonecfg.audio;
in
{
  options.theonecfg.audio.enable = lib.mkEnableOption "audio setup";

  config = lib.mkIf cfg.enable {
    hardware.bluetooth.enable = true;
    # hardware.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };
  };
}
