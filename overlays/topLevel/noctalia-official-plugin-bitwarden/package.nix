{ runCommand, noctalia-dev-official-plugins }:

runCommand "noctalia-official-plugin-bitwarden" { } ''
  cp -r ${noctalia-dev-official-plugins}/bitwarden $out
''
