_final: prev:
let

  inherit (prev.noctalia)
    version
    ;

in
{
  # kitty's theme hook touched kitty.conf before reading it. A home-manager
  # kitty.conf is a read-only symlink into the Nix store, so the hook failed
  # there and never reloaded kitty. The patch creates kitty.conf only when it
  # is missing: https://github.com/noctalia-dev/noctalia/pull/5566
  noctalia =
    if version != "5.6.0" then
      throw "overlays/fixes/noctalia: noctalia ${version}: if it carries noctalia-dev/noctalia#5566, delete this overlay; otherwise check the patch still applies and update this version"
    else
      prev.noctalia.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./kitty-do-not-touch-existing-config.patch ];
      });
}
