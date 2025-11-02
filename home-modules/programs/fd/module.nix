{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.theonecfg.home.programs.fd;
in
{
  options.theonecfg.home.programs.fd.enable = lib.mkEnableOption "fd config";

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [ fd ];

    xdg.enable = true;
    xdg.configFile."fd/ignore".text = ''
      .git
    '';

  };
}
