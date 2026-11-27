{ runCommand, noctalia-dev-official-plugins }:

runCommand "noctalia-official-plugin-world-clock" { } ''
  cp -r ${noctalia-dev-official-plugins}/world_clock $out
''
