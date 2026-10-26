{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib)
    types
    ;

  inherit (lib.modules)
    mkIf
    mkMerge
    ;

  inherit (lib.options)
    literalExpression
    mkEnableOption
    mkOption
    ;

  cfg = config.theonecfg.features.fonts;

in
{

  options.theonecfg.features.fonts = {

    desktop = {
      enable = mkEnableOption "theonecfg desktop fonts";

      packages = mkOption {
        type = types.listOf types.package;
        default = [
          pkgs.hack-font
          pkgs.noto-fonts
          pkgs.noto-fonts-cjk-sans
          pkgs.noto-fonts-color-emoji
          # pkgs.nerdfonts
        ];
        defaultText = literalExpression ''
          [
            pkgs.hack-font
            pkgs.noto-fonts
            pkgs.noto-fonts-cjk-sans
            pkgs.noto-fonts-color-emoji
            pkgs.nerdfonts
          ]
        '';
        description = ''
          Default developer fonts to install.
        '';
      };

      fontconfig.defaults = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = {
          monospace = [
            "Hack"
            "Noto Sans Mono"
          ];
          sansSerif = [ "Noto Sans" ];
          serif = [ "Noto Serif" ];
          emoji = [ "Noto Color Emoji" ];
        };
        defaultText = literalExpression ''
          {
            monospace = [ "Hack" "Noto Sans Mono" ];
            sansSerif = [ "Noto Sans" ];
            serif = [ "Noto Serif" ];
            emoji = [ "Noto Color Emoji" ];
          }
        '';
        description = ''
          System-wide default fonts.
        '';
      };
    };

    server.enable = mkEnableOption "theonecfg server fonts";

  };

  config = mkMerge [

    (mkIf cfg.desktop.enable {
      fonts.packages = cfg.desktop.packages;
      fonts.fontconfig.defaultFonts = cfg.desktop.fontconfig.defaults;
    })

    (mkIf cfg.server.enable {
      fonts.enableDefaultPackages = false;
      fonts.fontconfig.enable = false;
      fonts.fontDir.enable = false;
    })

  ];

}
