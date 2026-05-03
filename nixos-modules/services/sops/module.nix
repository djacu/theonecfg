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
    mkOption
    ;

  inherit (lib.types)
    str
    ;

  cfg = config.theonecfg.services.sops;

in
{
  options.theonecfg.services.sops = {
    enable = mkEnableOption "sops-nix host wiring";
    sshHostKeyPath = mkOption {
      type = str;
      default = "/etc/ssh/ssh_host_ed25519_key";
      description = ''
        Path to the SSH host private key sops-nix derives an age key
        from at activation. Default matches NixOS's standard location.
        On hosts where /etc is rolled back (impermanence), override to
        the persisted location, e.g. /persist/etc/ssh/ssh_host_ed25519_key.
      '';
    };
  };

  config = mkIf cfg.enable {
    sops.defaultSopsFile = ../../../secrets + "/${config.networking.hostName}.yaml";
    sops.age.sshKeyPaths = [ cfg.sshHostKeyPath ];
    sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  };
}
