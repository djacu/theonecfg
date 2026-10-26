{
  writeShellApplication,
  nix,
  nix-output-monitor,
}:
writeShellApplication {
  name = "nom-check";
  runtimeInputs = [
    nix
    nix-output-monitor
  ];
  text = ''
    nix flake check -Lvvv --log-format internal-json --keep-going 2>&1 | nom --json
  '';
}
