inputs:
let

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    mapAttrs
    ;

  inherit (lib.trivial)
    const
    ;

in
mapAttrs (const (
  pkgs:
  (inputs.treefmt-nix.lib.evalModule pkgs (
    { ... }:
    {
      config = {
        enableDefaultExcludes = true;
        projectRootFile = "flake.nix";
        programs = {
          mdformat.enable = true;
          mdsh.enable = true;
          nixfmt.enable = true;
          shellcheck.enable = true;
        };
        settings.global.excludes = [
          "*.gitignore"
          ".git-blame-ignore-revs"
          "notes/ores.md"
        ];
      };
    }
  ))
)) inputs.self.legacyPackages
