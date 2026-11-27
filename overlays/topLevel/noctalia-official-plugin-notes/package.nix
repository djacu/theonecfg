{ runCommand, noctalia-dev-official-plugins }:

runCommand "noctalia-official-plugin-notes" { } ''
  cp -r ${noctalia-dev-official-plugins}/notes $out
''
