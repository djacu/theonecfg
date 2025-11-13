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
      ]
      ++ (lib.optional config.networking.networkmanager.enable "networkmanager");
      shell = pkgs.fish;
    };
    programs.fish.enable = true;

    users.users.djacu.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEbH7DL3UpeYHm+J3YHJTIsnk/vdo5JgEzwD/Bf1tupp yubikey"
    ];

  };
}
