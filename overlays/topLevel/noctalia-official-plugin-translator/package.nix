{ runCommand, noctalia-dev-official-plugins }:

runCommand "noctalia-official-plugin-translator" { } ''
  cp -r ${noctalia-dev-official-plugins}/translator $out
''
