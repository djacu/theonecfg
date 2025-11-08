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

  inherit (theonecfg.library.path)
    joinPathSegments
    getDirectoryNames
    ;

  cfg = config.theonecfg.users.djacu;
in
{
  imports = map (joinPathSegments ./. "module.nix") (getDirectoryNames ./.);

  options.theonecfg.users.djacu.enable = lib.mkEnableOption "djacu user config";

  config = lib.mkIf cfg.enable {

    home.username = lib.mkDefault "djacu";
    home.homeDirectory = "/home/${config.home.username}";

    programs.home-manager.enable = true;

  };
}
