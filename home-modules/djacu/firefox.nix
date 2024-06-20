{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.theonecfg.users.djacu;
in
{
  options.theonecfg.users.djacu.firefox.enable = lib.mkEnableOption "djacu firefox config";

  config = lib.mkIf (cfg.enable && cfg.firefox.enable) {
    programs.firefox = {

      enable = true;

      profiles.personal = {
        id = 0;
        name = "Personal";
        isDefault = true;
        containers = {
          personal = {
            id = 1;
            name = "Personal";
            color = "turquoise";
            icon = "fingerprint";
          };
          shopping = {
            id = 2;
            name = "Shopping";
            color = "pink";
            icon = "cart";
          };
          banking = {
            id = 3;
            name = "Banking";
            color = "green";
            icon = "dollar";
          };
        };
        containersForce = true;

        extensions = with pkgs.nur.repos.rycee.firefox-addons; [
          bitwarden
          bypass-paywalls-clean
          consent-o-matic
          darkreader
          privacy-badger
          simple-translate
          sponsorblock
          to-google-translate
          translate-web-pages
          tree-style-tab
          tridactyl # TODO figure out how to customize
          ublock-origin
        ];

        settings = {
          "browser.bookmarks.showMobileBookmarks" = true; # Mobile bookmarks
          "browser.download.useDownloadDir" = false; # Ask for download location
          "browser.in-content.dark-mode" = true; # Dark mode
          "browser.newtabpage.activity-stream.feeds.section.topstories" = false; # Disable top stories
          "browser.newtabpage.activity-stream.feeds.sections" = false;
          "browser.newtabpage.activity-stream.feeds.system.topstories" = false; # Disable top stories
          "browser.newtabpage.activity-stream.section.highlights.includePocket" = false; # Disable pocket
          "extensions.autoDisableScopes" = 0; # Auto enable extensions
          "extensions.pocket.enabled" = false; # Disable pocket
          "media.eme.enable" = true; # Enable DRM
          "media.gmp-widevinecdm.enable" = true; # Enable DRM
          "media.gmp-widevinecdm.visible" = true; # Enable DRM
          "signon.autofillForms" = false; # Disable built-in form-filling
          "signon.rememberSignons" = false; # Disable built-in password manager
          "ui.systemUsesDarkTheme" = true; # Dark mode
        };

        search.engines = {
          "Nix Packages" = {
            urls = [
              {
                template = "https://search.nixos.org/packages";
                params = [
                  {
                    name = "type";
                    value = "packages";
                  }
                  {
                    name = "channel";
                    value = "unstable";
                  }
                  {
                    name = "query";
                    value = "{searchTerms}";
                  }
                ];
              }
            ];
            icon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
            definedAliases = [ "@np" ];
          };

          "NixOS Options" = {
            urls = [
              {
                template = "https://search.nixos.org/options";
                params = [
                  {
                    name = "type";
                    value = "packages";
                  }
                  {
                    name = "channel";
                    value = "unstable";
                  }
                  {
                    name = "query";
                    value = "{searchTerms}";
                  }
                ];
              }
            ];
            icon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
            definedAliases = [ "@no" ];
          };

          "nix.dev" = {
            urls = [
              {
                template = "https://nix.dev/search.html";
                params = [
                  {
                    name = "q";
                    value = "{searchTerms}";
                  }
                ];
              }
            ];
            icon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake-white.svg";
            definedAliases = [ "@nd" ];
          };

          "Bing".metaData.hidden = true;
          "eBay".metaData.hidden = true;
          "Google".metaData.alias = "@g";
        };
        search.force = true;
      };
    };
  };
}
