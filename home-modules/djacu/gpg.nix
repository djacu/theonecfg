{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.theonecfg.users.djacu.gpg;
in
{
  options.theonecfg.users.djacu.gpg.enable = lib.mkEnableOption "gpg config";

  config = lib.mkIf cfg.enable {

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

    # home.sessionVariables = {
    #   SSH_AUTH_SOCK = "$(gpgconf --list-dirs agent-ssh-socket)";
    # };

  };
}
