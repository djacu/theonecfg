# prowlarr-downloadclients vs qBittorrent WebUI readiness race

Status: open
Owner: dan
Last updated: 2026-06-07

## Symptom

On a cold boot of `scheelite`, `prowlarr-downloadclients.service` fails:

```
PUT /api/v1/downloadclient/1 (qBittorrent)
HTTP 400 from -X PUT -d {...} http://127.0.0.1:9696/api/v1/downloadclient/1
  "detailedDescription": "Connection refused (127.0.0.1:8080)",
  "errorMessage": "Unable to connect to qBittorrent"
1 item(s) failed; see FAIL lines above
prowlarr-downloadclients.service: Main process exited, code=exited, status=22/n/a
```

The unit lands in `failed` state and stays there until manually
restarted (or the next boot, where it may or may not race again).

## Root cause

The declarative download-client reconcilers built by
`mkArrApiPushService` (`library/declarative-arr.nix`) wait for the
\**target *arr's** API to answer (the `until curl ... ${endpoint}` loop,
~line 41) before pushing items. They do **not** wait for qBittorrent.

When the pushed item is a qBittorrent download client, the \*arr
validates it server-side by connecting to qBittorrent's WebUI
(`127.0.0.1:8080`). On a cold boot qBittorrent's systemd unit reports
`active` a moment before its WebUI actually accepts connections, so the
validation connect gets `Connection refused`, the \*arr returns HTTP 400,
and the reconcile script counts a failure and exits 22.

Observed timing on the 2026-06-07 reboot:

- qBittorrent unit active: `19:41:04`
- `prowlarr-downloadclients` ran: `19:41:05` (1 s later — WebUI not up yet)

Only `prowlarr-downloadclients` hit it. Prowlarr has no media-mount
dependency, so its reconcile fires earliest; `sonarr` / `sonarr-anime` /
`radarr` / `whisparr` download-client reconcilers ran later (they wait on
media mounts + their own slower-starting API) and **succeeded** because
qBittorrent's WebUI was ready by then.

Note: adding `after = [ "qbittorrent.service" ]` to the reconciler does
**not** fix this — qBittorrent's unit was already `active` before the
reconcile ran. The gap is *WebUI-readiness-after-unit-active*, which
`declarative-arr.nix:146` already calls out as a known distinction for
the \*arr-API wait. The fix has to poll the qBittorrent endpoint, not just
order after its unit.

## Scope / impact

- **Low.** The failing PUT updates an *existing* client (`id 1`); the
  prior entry persists, so qBittorrent integration keeps working — only
  the re-validation/update is skipped.
- **Cosmetic but persistent.** The unit shows in `systemctl --failed`
  after every cold boot that loses the race.
- **Pre-existing**, independent of the \*arr↔postgres ordering fix
  (`e482e97`). It only became visible once the \*arr apps stopped
  crashing on the postgres race and the reconcilers actually ran.

## Immediate remediation

```sh
sudo systemctl restart prowlarr-downloadclients.service
```

Succeeds once qBittorrent's WebUI is up.

## Proposed fix

Make `mkArrApiPushService` (or specifically the download-client
reconcilers) also wait for the qBittorrent WebUI before pushing, mirroring
the existing `until curl ... 200` readiness loop used for the \*arr API.
Options to weigh when implementing:

1. Add an optional `waitFor` list of `host:port` (or URLs) to
   `mkArrApiPushService` that the start script polls before reconciling.
   The download-client services pass qBittorrent's WebUI address. Keeps
   the dependency explicit and reusable.
1. Have the qBittorrent-client builders inject the wait automatically when
   a qBittorrent client is among the items, so callers don't have to
   remember.

Either way: poll the endpoint (don't just `after` the unit), and bound it
with the same timeout pattern as the existing arr-API wait so a genuinely
down qBittorrent still fails loudly rather than hanging.

## Verification (once fixed)

- Reboot `scheelite`; confirm `prowlarr-downloadclients.service` reaches
  `active (exited)` with no `Connection refused` in its journal.
- `systemctl --failed` is clean after boot across several reboots.
