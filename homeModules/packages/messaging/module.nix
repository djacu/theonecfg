{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.options)
    mkEnableOption
    ;

  inherit (lib.modules)
    mkIf
    ;

  cfg = config.theonecfg.packages.messaging;

  # Electron picks its secret store from the desktop's name. It knows GNOME
  # and KDE; under niri it falls back to "basic_text", which keeps the app's
  # encryption key on disk barely protected and makes Signal refuse a
  # database whose key was stored elsewhere. Under niri, start these apps
  # with the Secret Service backend named, so the key goes to the keyring.
  # The .desktop copy is for Slack, whose entry has an absolute Exec path
  # that would bypass the wrapper.
  withKeyring =
    pkg:
    if !config.theonecfg.programs.niri.enable then
      pkg
    else
      pkgs.symlinkJoin {
        name = "${pkg.name}-libsecret";
        paths = [ pkg ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          for bin in $out/bin/*; do
            wrapProgram "$bin" --add-flags "--password-store=gnome-libsecret"
          done
          for desktop in $out/share/applications/*.desktop; do
            if grep -q "${pkg}/bin/" "$desktop"; then
              cp --remove-destination "$(readlink -f "$desktop")" "$desktop"
              substituteInPlace "$desktop" --replace-fail "${pkg}/bin/" ""
            fi
          done
        '';
      };

in
{

  options.theonecfg.packages.messaging.enable = mkEnableOption "messaging package config";

  config = mkIf cfg.enable {

    home.packages = [

      (withKeyring pkgs.discord)
      (withKeyring pkgs.element-desktop)
      pkgs.fluffychat
      (withKeyring pkgs.signal-desktop)
      (withKeyring pkgs.slack)
      pkgs.karere

    ];

    nixpkgs.config.allowUnfree = true;

  };

}
