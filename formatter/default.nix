inputs:
inputs.nixpkgs-unstable.lib.genAttrs [
  "x86_64-linux"
  "aarch64-linux"
  "x86_64-darwin"
  "aarch64-darwin"
] (system: inputs.nixpkgs-unstable.legacyPackages.${system}.nixfmt-rfc-style)
