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

  cfg = config.theonecfg.profiles.common;
  isNotContainer = !config.boot.isContainer;

in
{
  options.theonecfg.profiles.common.enable = mkEnableOption "theonecfg common profile";

  config = mkIf cfg.enable {
    i18n.defaultLocale = "en_US.UTF-8";

    nix = {
      channel.enable = mkDefault false; # opt out of nix channels
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [ "@wheel" ];
      };
    };

    services.openssh.enable = mkDefault isNotContainer;
    services.openssh.extraConfig = ''
      StreamLocalBindUnlink yes
    '';

    services.pcscd.enable = mkDefault isNotContainer;

    services.xserver.xkb.options = "caps:swapescape";
    console.useXkbConfig = true;

  };
}
