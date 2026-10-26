inputs: final: _prev: {
  theonecfg-nixvimcfg = inputs.nixvimcfg.packages.${final.stdenv.hostPlatform.system}.default;
}
