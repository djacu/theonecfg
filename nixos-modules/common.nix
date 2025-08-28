{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.theonecfg.common;
  isNotContainer = !config.boot.isContainer;
in
{
  options.theonecfg.common.enable = lib.mkEnableOption "common config" // {
    default = true;
  };

  config = lib.mkIf cfg.enable {
    i18n.defaultLocale = "en_US.UTF-8";

    nix = {
      package = pkgs.nixVersions.nix_2_30;
      channel.enable = false; # opt out of nix channels
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [ "@wheel" ];
      };
    };

    services.openssh.enable = lib.mkDefault isNotContainer;

    services.pcscd.enable = lib.mkDefault isNotContainer;
  };
}
