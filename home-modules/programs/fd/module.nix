{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.theonecfg.programs.fd;
in
{
  options.theonecfg.programs.fd.enable = lib.mkEnableOption "fd config";

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [ fd ];

    xdg.enable = true;
    xdg.configFile."fd/ignore".text = ''
      .git
    '';

  };
}
