{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkForce
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.profiles.yubikey-live;

  guide = "${pkgs.drduh-yubikey-guide}/share/drduh-yubikey-guide";

  viewYubikeyGuide = pkgs.writeShellApplication {
    name = "view-yubikey-guide";
    runtimeInputs = [ pkgs.glow ];
    text = ''
      readme=${guide}/README.md
      # Inside a desktop session hand the file to the default viewer; on a
      # console render it in the terminal.
      if [ -n "''${WAYLAND_DISPLAY:-}''${DISPLAY:-}" ] && command -v xdg-open > /dev/null; then
        exec xdg-open "$readme"
      fi
      exec glow -p "$readme"
    '';
  };

in
{

  options.theonecfg.profiles.yubikey-live.enable =
    mkEnableOption "theonecfg air-gapped YubiKey live profile";

  config = mkIf cfg.enable {

    theonecfg.profiles.common.enable = true;

    # Everything on this system is ephemeral; nothing on it is worth a
    # password. Which user exists and logs in is the host's decision, so
    # this profile needs neither the theonecfg registry nor a desktop.
    security.sudo.wheelNeedsPassword = false;

    services.openssh.enable = false;
    programs.ssh.startAgent = false;

    swapDevices = [ ];
    boot.tmp.cleanOnBoot = true;
    boot.kernel.sysctl."kernel.unprivileged_bpf_disabled" = 1;

    # Air gap. plasma6 enables networkmanager with mkDefault, hence mkForce.
    boot.initrd.network.enable = false;
    networking = {
      resolvconf.enable = false;
      dhcpcd.enable = false;
      dhcpcd.allowInterfaces = [ ];
      interfaces = { };
      firewall.enable = true;
      useDHCP = false;
      useNetworkd = false;
      wireless.enable = false;
      networkmanager.enable = mkForce false;
    };

    # drduh's hardened gpg.conf for every user, root included: gpg reads
    # /etc/gnupg/gpg.conf before the user's own file.
    environment.etc."gnupg/gpg.conf".source = "${guide}/config/gpg.conf";
    programs.gnupg = {
      dirmngr.enable = false;
      agent = {
        enable = true;
        enableSSHSupport = true;
        pinentryPackage = pkgs.pinentry-qt;
        # drduh's gpg-agent.conf minus enable-ssh-support: a bare flag cannot
        # be expressed in the key-value format, and enableSSHSupport already
        # provides the socket.
        settings = {
          default-cache-ttl = 60;
          max-cache-ttl = 300;
        };
      };
    };
    services.udev.packages = [ pkgs.yubikey-personalization ];

    # No shell history on disk. HISTFILE is bash's; fish stops saving when
    # fish_history is the empty string.
    environment.interactiveShellInit = "unset HISTFILE";
    programs.fish.interactiveShellInit = ''set -g fish_history ""'';

    # The diceware generator, served to the local browser only.
    services.nginx = {
      enable = true;
      virtualHosts.diceware = {
        listen = [
          {
            addr = "127.0.0.1";
            port = 8080;
          }
        ];
        root = pkgs.diceware-page;
      };
    };

    environment.systemPackages = [
      pkgs.cryptsetup
      pkgs.diceware
      pkgs.drduh-yubikey-guide
      pkgs.ent
      pkgs.glow
      pkgs.gparted
      pkgs.htop
      pkgs.paperkey
      pkgs.parted
      pkgs.pcsc-tools
      pkgs.pgpdump
      pkgs.pwgen
      pkgs.tmux
      pkgs.yubico-piv-tool
      pkgs.yubikey-manager
      pkgs.yubikey-personalization
      viewYubikeyGuide
    ];

  };

}
