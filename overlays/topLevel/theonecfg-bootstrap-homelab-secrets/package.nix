{
  writeShellApplication,
  sops,
  openssl,
  util-linux,
  coreutils,
}:
writeShellApplication {
  name = "bootstrap-homelab-secrets";
  runtimeInputs = [
    sops
    openssl
    util-linux
    coreutils
  ];
  text = builtins.readFile ./bootstrap.sh;
}
