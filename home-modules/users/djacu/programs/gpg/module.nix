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
  options.theonecfg.users.djacu.programs.gpg.enable = lib.mkEnableOption "gpg config";

  config = lib.mkIf (cfg.enable && cfg.programs.gpg.enable) {

    programs.gpg = {
      enable = true;
      publicKeys = [
        {
          source = ./8C9CFEF8EE37DA95-2025-10-19.asc;
          trust = 5;
        }
      ];
      settings = {
        # https://github.com/drduh/config/blob/master/gpg.conf
        personal-cipher-preferences = "AES256 AES192 AES";
        personal-digest-preferences = "SHA512 SHA384 SHA256";
        personal-compress-preferences = "ZLIB BZIP2 ZIP Uncompressed";
        default-preference-list = "SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed";
        cert-digest-algo = "SHA512";
        s2k-digest-algo = "SHA512";
        s2k-cipher-algo = "AES256";
        charset = "utf-8";
        fixed-list-mode = true;
        no-comments = true;
        no-emit-version = true;
        keyid-format = "0xlong";
        list-options = "show-uid-validity";
        verify-options = "show-uid-validity";
        with-fingerprint = true;
        require-cross-certification = true;
        no-symkey-cache = true;
        use-agent = true;
        throw-keyids = true;
      };
    };

    services.gpg-agent = {
      enable = true;
      enableSshSupport = true;
      enableExtraSocket = true;
      pinentry.package = pkgs.pinentry-qt;
      /*
        To list all keys
        gpg --list-secret-keys --with-keygrip

        To get just the authentication key
        gpg --list-secret-keys --with-keygrip | awk 'flag { if (sub(/^.*Keygrip = /,"")) print; flag=0 } /\[A\]/{flag=1}'
      */
      sshKeys = [
        "7A2DE28AD784EA6161966F20069BC975AADF2C36"
      ];
    };

    home.sessionVariables = {
      XDG_RUNTIME_DIR = "/run/user/$UID";
      # SSH_AUTH_SOCK = "${builtins.getEnv "XDG_RUNTIME_DIR"}/gnupg/S.gpg-agent.ssh";
      SSH_AUTH_SOCK = "$(gpgconf --list-dirs agent-ssh-socket)";
      GPG_AGENT_SOCK = "/run/user/1000/gnupg/S.gpg-agent";
      GPG_EXTRA_SOCK = "/run/user/1000/gnupg/S.gpg-agent.extra";
    };
    # home.sessionVariables = {
    #   SSH_AUTH_SOCK = "$(gpgconf --list-dirs agent-ssh-socket)";
    # };

    programs.ssh.enable = true;
    # https://nix-community.github.io/home-manager/options.xhtml#opt-programs.ssh.enableDefaultConfig
    # programs.ssh.matchBlocks."*" = {
    #   forwardAgent = false;
    #   addKeysToAgent = "no";
    #   compression = false;
    #   serverAliveInterval = 0;
    #   serverAliveCountMax = 3;
    #   hashKnownHosts = false;
    #   userKnownHostsFile = "~/.ssh/known_hosts";
    #   controlMaster = "no";
    #   controlPath = "~/.ssh/master-%r@%n:%p";
    #   controlPersist = "no";
    # };
    programs.ssh.matchBlocks.malachite = {
      hostname = "malachite";
      forwardAgent = true;
      remoteForwards = [
        {
          bind.address = config.home.sessionVariables.GPG_AGENT_SOCK;
          host.address = config.home.sessionVariables.GPG_EXTRA_SOCK;
        }
        {
          bind.address = config.home.sessionVariables.GPG_AGENT_SOCK + ".ssh";
          host.address = config.home.sessionVariables.GPG_AGENT_SOCK + ".ssh";
        }
      ];
    };
    programs.ssh.matchBlocks.argentite = {
      hostname = "argentite";
      forwardAgent = true;
      remoteForwards = [
        {
          bind.address = config.home.sessionVariables.GPG_AGENT_SOCK;
          host.address = config.home.sessionVariables.GPG_EXTRA_SOCK;
        }
        {
          bind.address = config.home.sessionVariables.GPG_AGENT_SOCK + ".ssh";
          host.address = config.home.sessionVariables.GPG_AGENT_SOCK + ".ssh";
        }
      ];
    };

  };
}
