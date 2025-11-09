inputs: final: prev: {
  theonecfg = prev.theonecfg.overrideScope (
    finalScope: prevScope: {
      nixvimcfg = inputs.nixvimcfg.packages.${final.stdenv.hostPlatform.system}.default;
    }
  );
}
