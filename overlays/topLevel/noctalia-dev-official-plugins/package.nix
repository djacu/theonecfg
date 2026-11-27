# Source of the Noctalia team's official plugins. The single place to bump
# them: each noctalia-official-plugin-* package takes one directory from it.
# Before bumping, check every used plugin's plugin_api in its plugin.toml
# against the noctalia package's kCurrentPluginApiVersion
# (src/scripting/plugin_api.h); a newer one will not load.
{ fetchFromGitHub }:

fetchFromGitHub {
  owner = "noctalia-dev";
  repo = "official-plugins";
  rev = "96d289f50ff1ed72030872bf33c31e7d691c9d47";
  hash = "sha256-4GCFK4VSD9mlUoSW3hUAzNDVvtWdsEx4KMj3x02xhR0=";
}
