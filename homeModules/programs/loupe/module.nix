{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.programs.loupe;

  desktopFile = "${pkgs.loupe}/share/applications/org.gnome.Loupe.desktop";

in
{

  options.theonecfg.programs.loupe.enable = mkEnableOption "Loupe, GNOME's image viewer";

  config = mkIf cfg.enable {

    home.packages = [ pkgs.loupe ];

    # Open every image type Loupe declares in Loupe. xdg-mime edits
    # ~/.config/mimeapps.list in place, so the entries apps add themselves
    # are kept; xdg.mimeApps would take over the whole file instead.
    home.activation.loupeDefaultImageViewer = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      types=$(${pkgs.gnused}/bin/sed -n 's/^MimeType=//p' ${desktopFile} | ${pkgs.coreutils}/bin/tr ';' ' ')
      run ${pkgs.xdg-utils}/bin/xdg-mime default org.gnome.Loupe.desktop $types
    '';

  };

}
