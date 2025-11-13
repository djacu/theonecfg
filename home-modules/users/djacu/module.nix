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

  inherit (theonecfg.library.path)
    joinPathSegments
    getDirectoryNames
    ;

  cfg = config.theonecfg.users.djacu;
in
{
  imports = map (joinPathSegments ./. "module.nix") (getDirectoryNames ./.);

  options.theonecfg.users.djacu.enable = mkEnableOption "djacu user config";

  config = mkIf cfg.enable {

    home.username = "djacu";
    home.homeDirectory = "/home/${config.home.username}";

    programs.home-manager.enable = true;

  };
}
