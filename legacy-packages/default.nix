inputs:
inputs.self.library.systems.defaultSystems (
  system:
  import inputs.nixpkgs-unstable {
    inherit system;
    overlays = [ inputs.self.overlays.default ];
  }
)
