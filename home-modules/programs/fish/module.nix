{
  lib,
  pkgs,
  config,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    mkMerge
    ;

  cfg = config.theonecfg.home.programs.fish;

in
{
  options.theonecfg.home.programs.fish.enable = lib.mkEnableOption "fish config";

  config = mkIf cfg.enable (mkMerge [

    {
      programs.fish = {
        enable = true;
        generateCompletions = true;
      };
    }

    (mkIf config.theonecfg.home.programs.kitty.enable {
      programs.kitty = {
        shellIntegration.enableFishIntegration = true;
      };
    })

  ]);
}
