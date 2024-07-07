{
  lib,
  config,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.theonecfg.home.programs.agenix;
in
{

  options.theonecfg.home.programs.agenix.enable = lib.mkEnableOption "agenix config";

  config =
    lib.recursiveUpdate
      {

        age = {
          package = pkgs.theonecfg.age;
          identityPaths = inputs.self.identities;
          secretsDir = "${config.home.homeDirectory}/.agenix";
          secretsMountPoint = "${config.home.homeDirectory}/.agenix.d";
        };

        home.packages = [ pkgs.theonecfg.agenix ];

        # home.file.testkey = {
        #   target = ".secrets/ooooores";
        #   source = ../../notes/ores.md;
        # };

        # home.file.agenixEmpty = {
        #   target = ".agenix/empty";
        #   text = "";
        # };
        # home.file.agenixdEmpty = {
        #   target = ".agenix.d/empty";
        #   text = "";
        # };

        systemd.user.services.agenix = {
          # Unit = {
          #   After = "getty@tty3.service";
          # };
          Service = {
            Type = lib.mkForce "forking";
            StandardInput = "tty";
            StandardOutput = "inherit";
            StandardError = "inherit";
            # TTYPath = "/dev/tty3";
            # TTYReset = "yes";
            # TTYVHangup = "yes";
          };
        };

        home.file.".ssh/id_ed25519" = {
          target = ".ssh/id_ed25519";
          source = config.lib.file.mkOutOfStoreSymlink config.age.secrets.cassiterite_djacu_ssh_private.path;
        };
        home.file.".ssh/id_ed25519.pub" = {
          target = ".ssh/id_ed25519.pub";
          source = config.lib.file.mkOutOfStoreSymlink config.age.secrets.cassiterite_djacu_ssh_public.path;
        };

        # type mismatch
        # home.file.".ssh/id_ed25519".target = config.age.secrets.cassiterite_djacu_ssh_private.path;
        # home.file.".ssh/id_ed25519.pub".target = config.age.secrets.cassiterite_djacu_ssh_public.path;

        # impure
        # home.file.".ssh/id_ed25519".source = /. + config.age.secrets.cassiterite_djacu_ssh_private.path;
        # home.file.".ssh/id_ed25519.pub".source = /. + config.age.secrets.cassiterite_djacu_ssh_public.path;

        # nothing
        # age.secrets.cassiterite_djacu_ssh_private.path = "${config.home.homeDirectory}/.ssh/id_ed25519";
        # age.secrets.cassiterite_djacu_ssh_public.path = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";

        # nothing
        # age.secrets.cassiterite_djacu_ssh_private.path = ".ssh/id_ed25519";
        # age.secrets.cassiterite_djacu_ssh_public.path = ".ssh/id_ed25519.pub";

      }
      (
        let
          makeAgeSecrets =
            ageSecrets: secret:
            let
              secretName = lib.removeSuffix ".age" (builtins.baseNameOf secret);
            in
            lib.recursiveUpdate ageSecrets {
              age.secrets.${secretName} = {
                file = secret;
                # mode = "0600";
              };
            };

        in
        lib.foldl' makeAgeSecrets { } inputs.self.secrets
      );

}
