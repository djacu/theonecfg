{
  config,
  lib,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.features.zoxide;

in
{

  options.theonecfg.features.zoxide.enable = mkEnableOption "zoxide";

  config = mkIf cfg.enable {
    programs.zoxide.enable = true;
    programs.zoxide.enableZshIntegration = true;
    programs.zoxide.enableFishIntegration = true;
    programs.zoxide.enableBashIntegration = true;
  };

}
