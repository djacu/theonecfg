{
  lib,
  config,
  modulesPath,
  ...
}:
let
  cfg = config.theonecfg.simple-vm;
in
{
  imports = [
    #(modulesPath + "/profiles/graphical.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  options.theonecfg.simple-vm.enable = lib.mkEnableOption "simple vm config";

  config = lib.mkIf cfg.enable {
    system.stateVersion = "23.11";

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
