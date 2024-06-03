{ modulesPath, ... }:
{
  imports = [
    #(modulesPath + "/profiles/graphical.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  system.stateVersion = "24.05";

  nixpkgs.hostPlatform = "x86_64-linux";

  theonecfg.simple-vm.enable = true;
  theonecfg.common.enable = true;
}
