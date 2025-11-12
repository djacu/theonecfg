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
    joinParentToPaths
    getDirectoryNames
    ;

in
{
  imports = map (
    dir:
    joinParentToPaths ./. [
      dir
      "module.nix"
    ]
  ) (getDirectoryNames ./.);
}
