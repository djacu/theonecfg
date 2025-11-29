{
  config,
  lib,
  pkgs,
  theonecfg,
  ...
}:
let

  inherit (builtins)
    baseNameOf
    ;

  username = baseNameOf ./.;

  cfg = config.theonecfg.users.${username};

in
{
  options.theonecfg.users.${username}.enable = lib.mkEnableOption "user ${username} setup";

  config = lib.mkIf cfg.enable (
    lib.mkMerge [

      {
        users.users.${username} = {

          inherit (theonecfg.knownUsers.${username})
            uid
            ;

          isNormalUser = true;

          extraGroups = [
            "wheel"
          ]
          ++ (lib.optional config.networking.networkmanager.enable "networkmanager");

        };
      }

      # TODO @djacu DO BETTER
      {
        users.users.${username}.shell = pkgs.fish;
        programs.fish.enable = true;

        environment.systemPackages = [
          pkgs.sops
        ];
      }

      {
        users.users.${username}.openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEbH7DL3UpeYHm+J3YHJTIsnk/vdo5JgEzwD/Bf1tupp yubikey"
        ];
      }

    ]
  );
}
