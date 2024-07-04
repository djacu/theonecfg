inputs:
let
  inherit (inputs.nixpkgs-unstable.lib) fileset;
in
fileset.toList (fileset.fileFilter (file: !file.hasExt "nix") ./.)
