{
  jq,
  lib,
  nix-eval-jobs,
  nix-output-monitor,
  stdenv,
  writeShellApplication,
}:
let

  inherit (lib.filesystem)
    baseNameOf
    ;

in
writeShellApplication {

  name = baseNameOf ./.;

  runtimeInputs = [
    jq
    nix-eval-jobs
    nix-output-monitor
  ];

  text = ''
    usage() {
      cat <<USAGE
    Usage: verify-hydra-jobset JOBFILE [OPTIONS] [-- NOM_ARGS...]

    Evaluate a hydra jobset nix file and build all resulting derivations.
    Exits non-zero on evaluation errors or build failures.

    Arguments:
      JOBFILE                Nix file to evaluate (e.g. ./nix/hydra-jobs/packages.nix)

    Options:
      --max-memory-size MB   Max memory per nix-eval-jobs worker in MB (default: 4096)
      --workers N            Number of nix-eval-jobs workers (default: 1)
      -h, --help             Show this help message

    All other arguments are forwarded to nom build.
    USAGE
    }

    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
      usage
      exit 0
    fi

    jobfile="$1"
    shift

    if [[ ! -f "$jobfile" ]]; then
      echo "error: file not found: $jobfile" >&2
      exit 1
    fi

    max_memory_size=4096
    workers=1
    nom_args=()

    while [[ $# -gt 0 ]]; do
      case "$1" in
        -h|--help) usage; exit 0 ;;
        --max-memory-size) max_memory_size="$2"; shift 2 ;;
        --workers) workers="$2"; shift 2 ;;
        *) nom_args+=("$1"); shift ;;
      esac
    done

    eval_output=$(mktemp)
    trap 'rm -f "$eval_output"' EXIT

    echo "Evaluating $jobfile with $workers worker(s)..."

    nix-eval-jobs \
      "$jobfile" \
      --arg supportedSystems '["${stdenv.hostPlatform.system}"]' \
      --constituents \
      --force-recurse \
      --max-memory-size "$max_memory_size" \
      --workers "$workers" \
      > "$eval_output"

    jq -cr '.constituents + [.drvPath] | .[] | select(.!=null) + "^*"' < "$eval_output" \
      | nom build \
      --no-allow-import-from-derivation \
      --keep-going \
      --no-link \
      --print-out-paths \
      --stdin \
      "''${nom_args[@]}"
    build_exit=$?

    eval_errors=$(jq -c 'select(.error != null) | {attr, error}' < "$eval_output")
    if [[ -n "$eval_errors" ]]; then
      echo ""
      echo "=== Evaluation errors ==="
      echo "$eval_errors" | jq .
      echo ""
      exit 1
    fi

    exit "$build_exit"
  '';

}
