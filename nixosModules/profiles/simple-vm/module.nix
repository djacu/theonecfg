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

  cfg = config.theonecfg.profiles.simple-vm;

in
{
  options.theonecfg.profiles.simple-vm.enable = mkEnableOption "simple vm config";

  config = mkIf cfg.enable {
    # Configure networking
    networking.useDHCP = false;
    networking.interfaces.eth0.useDHCP = true;

    # Create user "test"
    services.getty.autologinUser = "test";
    users.users.test.isNormalUser = true;
    users.users.test.hashedPassword = "$6$g5tuFwUbC/.g6Dn$LKpzULxoyHURkhk1AEEIONnoRkXzSO3vOjJx/jL7LwlYbSZnXgDnYGFahpOfDEj944mgZ0CmElXaxmRrJtmST.";

    # Enable passwordless ‘sudo’ for the "test" user
    users.users.test.extraGroups = [ "wheel" ];
    security.sudo.wheelNeedsPassword = false;

    # Make VM output to the terminal instead of a separate window
    virtualisation.vmVariant.virtualisation.graphics = false;
  };
}
