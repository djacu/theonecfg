{
  jq,
  nix-eval-jobs,
  nix-output-monitor,
  stdenv,
  writeShellApplication,
}:
writeShellApplication {

  name = builtins.baseNameOf ./.;

  runtimeInputs = [
    jq
    nix-eval-jobs
    nix-output-monitor
  ];

  text = ''
    nix-eval-jobs --flake .#hydraJobs.homeConfigs.${stdenv.hostPlatform.system} --constituents > jobs.json
    jq -cr '.constituents + [.drvPath] | .[] | select(.!=null) + "^*"' <jobs.json | \
    nom build --keep-going --no-link --print-out-paths --stdin "$@"
    echo "These derivations failed to evaluate: $(jq -s 'map(select(.error != null)) | map(.attr)' <jobs.json)"
    exit "$(jq -s 'map(select(.error != null)) | [length, 1] | min' <jobs.json)"
  '';

}
