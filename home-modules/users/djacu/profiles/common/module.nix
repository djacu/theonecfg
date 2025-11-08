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

  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.profiles.common.enable = mkEnableOption "djacu common profile";

  config = mkIf (cfg.enable && cfg.profiles.common.enable) {

    theonecfg.users.djacu.programs.git.enable = true;
    theonecfg.users.djacu.programs.gpg.enable = true;
    theonecfg.users.djacu.programs.nix.enable = true;

  };
}
