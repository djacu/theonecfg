{ runCommand, noctalia-dev-official-plugins }:

runCommand "noctalia-official-plugin-screen-recorder" { } ''
  cp -r ${noctalia-dev-official-plugins}/screen_recorder $out
''
