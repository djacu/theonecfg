{
  lib,
  ...
}:
let

  inherit (builtins)
    readDir
    ;

  inherit (lib.attrsets)
    attrNames
    filterAttrs
    ;

  inherit (lib.lists)
    map
    ;

  inherit (lib.trivial)
    const
    ;

in
{
  imports = map (directory: ./${directory}/module.nix) (
    attrNames (filterAttrs (const (filetype: filetype == "directory")) (readDir ./.))
  );
}
