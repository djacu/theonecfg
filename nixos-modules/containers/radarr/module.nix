{
  config,
  lib,
  # theonecfg,
  ...
}:

let

  inherit (lib.modules)
    mkIf
    ;

  inherit (lib.options)
    mkEnableOption
    ;

  cfg = config.theonecfg.containers.radarr;

in

{

  options.theonecfg.containers.radarr.enable = mkEnableOption "theonecfg radarr container";

  config = {

    networking.firewall.allowedTCPPorts = [
      7878
    ];

    containers.radarr = mkIf cfg.enable {

      autoStart = true;

      # bindMounts = {
      #   "/etc/ssh/ssh_host_ed25519_key".isReadOnly = true;
      #   "/etc/ssh/ssh_host_ed25519_key.pub".isReadOnly = true;
      # };

      config =
        {
          config,
          ...
        }:

        let

          radarrUser = config.services.radarr.user;

        in

        {

          # imports = [
          #   theonecfg.externalModules.sops-nix
          # ];

          system.stateVersion = "25.05";

          services.radarr = {
            enable = true;
            openFirewall = true;
            settings = {
              postgres.host = "127.0.0.1";
              postgres.logdb = "radarr-log";
              postgres.maindb = "radarr-main";
              postgres.password = radarrUser;
              postgres.user = radarrUser;
              server.port = 7878;
            };
          };

          services.postgresql = {
            authentication = ''
              # type database user address method
              local all all trust
              host all ${radarrUser} 127.0.0.1/32 trust
              host all ${radarrUser} ::1/128      trust
            '';
            enable = true;
            ensureDatabases = [
              "radarr-log"
              "radarr-main"
            ];
            ensureUsers = [
              {
                name = radarrUser;
                ensureClauses.superuser = true;
              }
            ];
          };

        };

    };

  };

}
