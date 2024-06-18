{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    literalExpression
    mkOption
    mkEnableOption
    mkIf
    mkMerge
    types
    ;

  cfg = config.theonecfg.fonts;
in
{
  options.theonecfg.fonts = {
    dev = {
      enable = mkEnableOption "developer fonts";

      packages = mkOption {
        type = types.listOf types.package;
        default = [
          pkgs.hack-font
          pkgs.noto-fonts
          pkgs.noto-fonts-cjk-sans
          pkgs.noto-fonts-color-emoji
          pkgs.nerdfonts
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

    server.enable = mkEnableOption "server fonts";
  };

  config = mkMerge [
    (mkIf cfg.dev.enable {
      fonts.packages = cfg.dev.packages;
      fonts.fontconfig.defaultFonts = cfg.dev.fontconfig.defaults;
    })

    (lib.mkIf cfg.server.enable {
      fonts.enableDefaultPackages = false;
      fonts.fontconfig.enable = false;
      fonts.fontDir.enable = false;
    })
  ];
}
