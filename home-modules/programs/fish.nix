{
  lib,
  pkgs,
  config,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    mkMerge
    ;

  cfg = config.theonecfg.home.programs.fish;

in
{
  options.theonecfg.home.programs.fish.enable = lib.mkEnableOption "fish config";

  config = mkIf cfg.enable (mkMerge [

    {
      programs.fish = {
        enable = true;
        generateCompletions = true;
      };

      # Fish startup guard: prefer forwarded SSH_AUTH_SOCK, else local gpg socket
      home.file.".config/fish/conf.d/10-ssh-auth-sock.fish".text = ''
        function __forwarded_agent --description "Detect forwarded SSH agent"
            if test -n "$SSH_AUTH_SOCK"; and test -S "$SSH_AUTH_SOCK"
                if string match -qr '^/tmp/ssh-.*/agent\..*$' -- $SSH_AUTH_SOCK
                    return 0
                end
            end
            return 1
        end

        if __forwarded_agent
            # keep forwarded agent
        else
            set -l gpg_sock (gpgconf --list-dirs agent-ssh-socket ^/dev/null)
            if test -n "$gpg_sock"; and test -S "$gpg_sock"
                set -gx SSH_AUTH_SOCK "$gpg_sock"
            end
        end
        functions -e __forwarded_agent
      '';
    }

    (mkIf config.theonecfg.home.programs.kitty.enable {
      programs.kitty = {
        shellIntegration.enableFishIntegration = true;
      };
    })

  ]);
}
