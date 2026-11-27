{ runCommand, noctalia-dev-official-plugins }:

runCommand "noctalia-official-plugin-kaomoji" { } ''
  cp -r ${noctalia-dev-official-plugins}/kaomoji $out
''
