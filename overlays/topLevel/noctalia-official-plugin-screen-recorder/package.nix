{ applyPatches, noctalia-dev-official-plugins }:

applyPatches {
  name = "noctalia-official-plugin-screen-recorder";
  src = "${noctalia-dev-official-plugins}/screen_recorder";
  # Stops "Recording saved" from showing twice; see the patch header.
  patches = [ ./own-recorder-process.patch ];
}
