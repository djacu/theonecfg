{
  writeShellApplication,
  theonecfg,
  docopts,
  gnupg,
  pinentry-tty,
}:
writeShellApplication {

  name = "make-gpg-master";

  runtimeInputs = [
    docopts
    gnupg
    pinentry-tty
  ];

  # remove errexit because it hides docopts errors
  bashOptions = [
    "nounset"
    "pipefile"
  ];

  text = ''
    # Make a GPG master key
    #
    # Usage:
    #   make-gpg-master USERID [--homedir=path] [--algo=name [--usage=certs [--expire=date]]]
    #   make-gpg-master (-h | --help)
    #   make-gpg-master --version
    #
    # Arguments:
    #   USERID            User ID.
    #
    # Options:
    #   -h --help         Show this screen.
    #   --version         Show version.
    #   --homedir=path    GPG home directory [default: temp-gpg-home].
    #   --algo=name       Algorithm [default: ed25519].
    #   --usage=certs     Usage for this cert [default: sign,cert].
    #   --expire=date     Date key expires [default: 0].
    #

    # shellcheck disable=SC1091
    source ${theonecfg.docopts-helpers}

    help=$(docopt_get_help_string "$0")
    version='0.1'

    parsed=$(docopts -A myargs -h "$help" -V $version : "$@")
    eval "$parsed"

    # main code

    gpg_base=("gpg" "--batch" "--no-permission-warning" "--quick-generate-key")

    gpg_args=()

    option_keys=("--homedir")
    for option_key in "''${option_keys[@]}"
    do
      gpg_args+=("$option_key")
      gpg_args+=("''${myargs[$option_key]}")
    done

    option_keys=("USERID" "--algo" "--usage" "--expire")
    for option_key in "''${option_keys[@]}"
    do
      gpg_args+=("''${myargs[$option_key]}")
    done

    gpg_command=("''${gpg_base[@]}" "''${gpg_args[@]}")

    mkdir "''${myargs[--homedir]}"

    # need to tell gpg-agent the exact path to pinentry
    echo "pinentry-program ${pinentry-tty}/bin/pinentry" > "''${myargs[--homedir]}/gpg-agent.conf"

    "''${gpg_command[@]}"
  '';

}
