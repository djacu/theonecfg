{
  config,
  lib,
  ...
}:
let

  inherit (lib.options)
    mkEnableOption
    ;

  inherit (lib.modules)
    mkIf
    ;

  cfg = config.theonecfg.programs.mpv;

in
{

  options.theonecfg.programs.mpv.enable = mkEnableOption "mpv config";

  config = mkIf cfg.enable {
    programs.mpv.enable = true;
  };

}
