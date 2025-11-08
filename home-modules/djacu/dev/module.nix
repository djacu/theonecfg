{
  lib,
  config,
  ...
}:
let
  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.dev.enable = lib.mkEnableOption "djacu dev config";

  config = lib.mkIf (cfg.enable && cfg.dev.enable) {

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
