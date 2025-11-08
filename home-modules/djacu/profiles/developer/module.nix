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

    theonecfg.users.djacu.git.enable = true;
    theonecfg.users.djacu.fish.enable = false;

    theonecfg.home.programs.fd.enable = true;
    theonecfg.home.programs.fish.enable = true;
    theonecfg.home.programs.nixvimcfg.enable = true;
    theonecfg.home.programs.tmux.enable = true;

    theonecfg.packages.admin.enable = true;
    theonecfg.packages.developer.enable = true;
    theonecfg.packages.networking.enable = true;
    theonecfg.packages.nix.enable = true;

  };
}
