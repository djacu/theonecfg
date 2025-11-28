{
  config,
  lib,
  theonecfg,
  ...
}:
let

  inherit (lib.lists)
    map
    ;

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  inherit (lib.trivial)
    flip
    pipe
    ;

  inherit (theonecfg.library.path)
    getDirectoryNames
    joinParentToPaths
    ;

  cfg = config.theonecfg.users.djacu;
in
{
  imports = map (flip pipe [
    (joinParentToPaths ./.)
    (flip joinParentToPaths "module.nix")
  ]) (getDirectoryNames ./.);

  options.theonecfg.users.djacu.enable = mkEnableOption "djacu user config";

  config = mkIf cfg.enable {

    home.username = "djacu";
    home.homeDirectory = "/home/${config.home.username}";

    programs.home-manager.enable = true;

  };
}
