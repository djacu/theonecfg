{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.theonecfg.users.djacu;
  cfgFirefox = cfg.firefox;
in
{
  options.theonecfg.users.djacu.firefox = {
    enable = lib.mkEnableOption "djacu firefox config";
    tridactyl.enable = lib.mkEnableOption "djacu firefox tridactyl config" // {
      default = cfgFirefox.enable;
    };
  };

  config = lib.mkIf (cfg.enable && cfgFirefox.enable) (
    lib.mkMerge [
      {
        programs.firefox = {

          enable = true;

          package = pkgs.firefox.override {
            nativeMessagingHosts = (lib.optional cfgFirefox.tridactyl.enable pkgs.tridactyl-native);
          };

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

            extensions.packages =
              with pkgs.nur.repos.rycee.firefox-addons;
              (
                [
                  bitwarden
                  # bypass-paywalls-clean # TODO: find a replacement
                  consent-o-matic
                  darkreader
                  multi-account-containers
                  privacy-badger
                  simple-translate
                  sponsorblock
                  to-google-translate
                  translate-web-pages
                  tree-style-tab
                  ublock-origin
                ]
                ++ (lib.optional cfgFirefox.tridactyl.enable tridactyl)
              );

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

              "bing".metaData.hidden = true;
              "ebay".metaData.hidden = true;
              "google".metaData.alias = "@g";
            };
            search.force = true;
          };
        };
      }

      (lib.mkIf cfgFirefox.tridactyl.enable {
        home.file.".config/tridactyl/tridactylrc".text = ''
          " "
          " " Unbind
          " "
          "
          " " Use browser's native find with Ctrl-f
          unbind <C-f>
          "
          " "
          " " Binds
          " "
          "
          " " Disable tridactyl on this page
          command shutup mode ignore
          "
          " " Search forward/backword
          bind / fillcmdline find
          bind ? fillcmdline find -?
          "
          " " Go to next/previous match
          bind n findnext 1
          bind N findnext -1
          "
          " " GitHub pull request checkout command to clipboard (only works if you're a collaborator or above)
          bind yp composite js document.getElementById("clone-help-step-1").textContent.replace("git checkout -b", "git checkout -B").replace("git pull ", "git fetch ") + "git reset --hard " + document.getElementById("clone-help-step-1").textContent.split(" ")[3].replace("-","/") | yank
          " 
          " " Git{Hub,Lab} git clone via SSH yank
          bind yg composite js "git clone " + document.location.href.replace(/https?:\/\//,"git@").replace("/",":").replace(/$/,".git") | clipboard yank
          "
          " " Binds for new reader mode
          bind gr reader
          bind gR reader --tab
          "
          " "
          " " Misc
          " "
          "
          colorscheme dark
          "
          " " Defaults to 300ms but I'm a 'move fast and close the wrong tabs' kinda chap
          set hintdelay 100
          " 
          " "
          " " Quickmarks - use go[key], gn[key], or gw[key] to open, tabopen, or winopen the URL respectively
          " "
          "
          quickmark c calendar.google.com
          quickmark g github.com
          quickmark y youtube.com
          " 
          " "
          " " Search URLs - use (o|t|w) <url> <search-terms>
          " "
          "
          " " Delete default github searchurl
          setnull searchurls.github
          "
          " " Set search urls
          set searchurls.gh https://github.com/search?q=
          set searchurls.yt https://www.youtube.com/results?search_query=
          set searchurls.hm https://home-manager-options.extranix.com/?query=
          set searchurls.np https://search.nixos.org/packages?channel=unstable&from=0&size=50&sort=relevance&type=packages&query=
          set searchurls.no https://search.nixos.org/options?channel=unstable&from=0&size=50&sort=relevance&type=packages&query=
          set searchurls.nd https://nix.dev/search.html?q=
          "
        '';
      })
    ]
  );
}
