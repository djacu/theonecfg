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
  options.theonecfg.users.djacu.profiles.developer.enable = mkEnableOption "djacu developer profile";

  config = mkIf (cfg.enable && cfg.profiles.developer.enable) {

    theonecfg.users.djacu.fish.enable = false;

    theonecfg.programs.fd.enable = true;
    theonecfg.programs.fish.enable = true;
    theonecfg.programs.nixvimcfg.enable = true;
    theonecfg.programs.tmux.enable = true;

    theonecfg.packages.admin.enable = true;
    theonecfg.packages.developer.enable = true;
    theonecfg.packages.networking.enable = true;
    theonecfg.packages.nix.enable = true;

  };
}
