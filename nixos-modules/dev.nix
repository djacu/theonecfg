{ lib, config, ... }:
let
  cfg = config.theonecfg.dev;
in
{
  options.theonecfg.dev.enable = lib.mkEnableOption "dev setup";

  config = lib.mkIf cfg.enable {
    # theonecfg.zsh.enable = true;
    theonecfg.zoxide.enable = true;
    programs.ssh.startAgent = false;
  };
}
