{
  lib,
  pkgs,
  config,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.audio;

in
{
  options.theonecfg.audio.enable = mkEnableOption "audio setup";

  config = mkIf cfg.enable {

    # for pactl
    environment.systemPackages = with pkgs; [
      pulseaudio
      pamixer
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
