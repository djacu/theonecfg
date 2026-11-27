{ runCommand, noctalia-dev-official-plugins }:

runCommand "noctalia-official-plugin-timer" { } ''
  cp -r ${noctalia-dev-official-plugins}/timer $out
''
