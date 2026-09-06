{
  lib,
  config,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    mkMerge
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.users.djacu;

in
{
  options.theonecfg.users.djacu.programs.fish.enable = mkEnableOption "djacu fish config";

  config = mkMerge [
    # qbt-add rides the umbrella enable only: the fish sub-gate below opts
    # hosts out of djacu's fish *config* (ssh-agent forwarding, mid-rework),
    # and this helper shouldn't hide behind that.
    (mkIf cfg.enable {
      # Batch-add torrent files to scheelite's qBittorrent with one category.
      # Works around qBt 5.2.0-5.2.3's WebUI opening a separate add dialog per
      # file (upstream restores a shared dialog in 5.2.4). Streams each file
      # over ssh into the localhost-only API (no auth needed on the host, no
      # temp files). Usage: qbt-add <category> <file.torrent>...
      programs.fish.functions.qbt-add = ''
        if test (count $argv) -lt 2
            echo "usage: qbt-add <category> <file.torrent>..." >&2
            return 1
        end
        set -l category $argv[1]
        if not string match -qr '^[A-Za-z0-9._-]+$' -- $category
            echo "qbt-add: category must be a plain word: $category" >&2
            return 1
        end
        set -l failed 0
        for f in $argv[2..]
            if not test -f "$f"
                echo "skip (not a file): $f" >&2
                set failed 1
                continue
            end
            set -l resp (ssh djacu@scheelite "curl -s -F 'category=$category' -F 'torrents=@-;filename=upload.torrent' http://127.0.0.1:8080/api/v2/torrents/add" < "$f")
            echo "$resp  <- "(basename "$f")
            if test "$resp" != "Ok."
                set failed 1
            end
        end
        return $failed
      '';
    })

    (mkIf (cfg.enable && cfg.programs.fish.enable) {
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
    })
  ];
}
