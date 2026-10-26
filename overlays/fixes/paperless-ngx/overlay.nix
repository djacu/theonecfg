final: prev:
let

  inherit (final.lib.strings)
    versionAtLeast
    ;

  inherit (prev.paperless-ngx)
    version
    ;

in
{
  # Backport of paperless-ngx PR 14249 (first released in 3.3.0). The consumer
  # derived a document's created date with fromtimestamp in the system zone and
  # then tagged it with Django's zone, so inside the UTC build sandbox the test
  # suite fails between 00:00 and 05:00 UTC, when the America/Chicago test
  # zone is still on the previous day.
  paperless-ngx =
    if versionAtLeast version "3.3.0" then
      throw "overlays/fixes/paperless-ngx: paperless-ngx ${version} already carries upstream PR 14249; delete this overlay"
    else
      prev.paperless-ngx.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (final.fetchpatch {
            name = "paperless-ngx-created-date-in-configured-time-zone.patch";
            url = "https://github.com/paperless-ngx/paperless-ngx/commit/abf5050ea700a06e4f0269d43297ba890efc0700.patch";
            hash = "sha256-pHnr0lZuIiq/Y1KNtTdgSRrAuLA5CgzKHQ2jcYCronE=";
          })
        ];
      });
}
