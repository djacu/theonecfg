{
  lib,
  config,
  ...
}:
let
  cfg = config.theonecfg.programs.zellij;
in
{
  options.theonecfg.programs.zellij.enable = lib.mkEnableOption "zellij config";

  config = lib.mkIf cfg.enable {
    programs.zellij = {
      enable = true;
      enableBashIntegration = true;
      enableFishIntegration = true;
      enableZshIntegration = true;
      settings = {
        theme = "nord";
      };
    };
  };
}
