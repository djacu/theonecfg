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
    # SSH-derived age key only. sshKeyPaths and keyFile are independent
    # and additive in sops-install-secrets — setting keyFile means
    # sops-nix REQUIRES the file to exist (it's a hard read with no
    # fallback to sshKeyPaths). Leaving keyFile null means sops-nix uses
    # only the SSH-derived key, which is what we want here since the
    # secrets file is already encrypted to that recipient.
    sops.age.sshKeyPaths = [ cfg.sshHostKeyPath ];
  };
}
