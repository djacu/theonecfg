{
  release = "jfly";
  modules =
    {
      modulesPath,
      pkgs,
      ...
    }:
    {

      imports = [
        (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")

        # Provide an initial copy of the NixOS channel so that the user
        # doesn't need to run "nix-channel --update" first.
        (modulesPath + "/installer/cd-dvd/channel.nix")
      ];

      hardware.deviceTree.name = "qcom/sc8280xp-lenovo-thinkpad-x13s.dtb";

      nixpkgs.buildPlatform = "x86_64-linux";
      nixpkgs.hostPlatform = "aarch64-linux";

      environment.systemPackages = [ pkgs.neovim ];

    };
}
