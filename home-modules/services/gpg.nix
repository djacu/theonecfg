{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.theonecfg.home.services.gpg;
in
{
  options.theonecfg.home.services.gpg.enable = lib.mkEnableOption "gpg config";

  config = lib.mkIf cfg.enable {
    services.gpg-agent.enable = true;
    services.gpg-agent.pinentry.package = pkgs.pinentry-tty;
  };
}
