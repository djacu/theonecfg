{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.enable = lib.mkEnableOption "user djacu setup";

  config = lib.mkIf cfg.enable {
    users.users.djacu = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
      ] ++ (lib.optional config.networking.networkmanager.enable "networkmanager");
      shell = pkgs.fish;
    };
    programs.fish.enable = true;
  };
}
