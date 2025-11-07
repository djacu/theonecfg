{
  lib,
  theonecfg,
  ...
}:
let

  inherit (lib.lists)
    map
    ;

  inherit (theonecfg.library.path)
    joinPathSegments
    getDirectoryNames
    ;

in
{
  imports = map (joinPathSegments ./. "module.nix") (getDirectoryNames ./.);
}
