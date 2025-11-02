{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    literalExpression
    mkOption
    mkEnableOption
    mkIf
    types
    ;

  cfg = config.theonecfg.zoxide;

  cfgOptions = concatStringsSep " " cfg.options;
in
{

  options.theonecfg.zoxide = {
    enable = mkEnableOption "zoxide";

    package = mkOption {
      type = types.package;
      default = pkgs.zoxide;
      defaultText = literalExpression "pkgs.zoxide";
      description = ''
        Zoxide package to install.
      '';
    };

    options = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--no-aliases" ];
      description = ''
        List of options to pass to zoxide.
      '';
    };

    enableBashIntegration = mkOption {
      default = true;
      type = types.bool;
      description = ''
        Whether to enable Bash integration.
      '';
    };

    enableZshIntegration = mkOption {
      default = true;
      type = types.bool;
      description = ''
        Whether to enable Zsh integration.
      '';
    };

    enableFishIntegration = mkOption {
      default = true;
      type = types.bool;
      description = ''
        Whether to enable Fish integration.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    programs.bash.interactiveShellInit = mkIf cfg.enableBashIntegration ''
      eval "$(${cfg.package}/bin/zoxide init bash ${cfgOptions})"
    '';

    programs.zsh.interactiveShellInit = mkIf cfg.enableZshIntegration ''
      eval "$(${cfg.package}/bin/zoxide init zsh ${cfgOptions})"
    '';

    programs.fish.interactiveShellInit = mkIf cfg.enableFishIntegration ''
      ${cfg.package}/bin/zoxide init fish ${cfgOptions} | source
    '';
  };
}
