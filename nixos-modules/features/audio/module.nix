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

  cfg = config.theonecfg.features.audio;

in
{

  options.theonecfg.features.audio.enable = mkEnableOption "theonecfg audio setup";

  config = mkIf cfg.enable {

    # for pactl
    environment.systemPackages = [
      pkgs.pulseaudio
      pkgs.pamixer
    ];

    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    services.pulseaudio.enable = false;

    security.rtkit.enable = true;

  };

}
