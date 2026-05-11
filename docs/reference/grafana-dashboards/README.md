# Homelab Grafana starter dashboards

Three importable JSON dashboards for the `scheelite` observability stack
(Prometheus + Loki + node_exporter + zfs_exporter + smartctl_exporter +
Alloy/journald). They are intentionally simple — clear panels, sensible
thresholds, no alerts, no recording rules.

## Dashboards

- `homelab-host-overview.json` — host vitals: uptime, CPU%, memory, root
  and `/tank0` fill, network on `eno1`, load average, count of failed
  systemd units.
- `homelab-storage.json` — ZFS pool health/capacity/fragmentation, free
  space per pool, drive temperatures vs each drive's own `drive_trip`
  threshold, SMART pass/fail count, top datasets by used bytes.
- `homelab-logs.json` — Loki log explorer over `job="systemd-journal"`
  with unit and level filters, log volume over time, error counts at 1h
  and 24h, and a top-10 noisiest-units table.

## Importing

In Grafana:

1. Sidebar → **Dashboards** → **New** → **Import**.
2. Click **Upload JSON file** and pick one of the `homelab-*.json` files
   above (or paste the JSON into the textarea).
3. On the Import screen: leave the title as-is, leave the UID as-is.
   Grafana will pre-fill the `Prometheus` and `Loki` datasources because
   the JSON references them by name; confirm and click **Import**.

Repeat for each of the three files.

## Logs dashboard variables

The Logs dashboard exposes two template variables at the top:

- **`unit`** — multi-select of every systemd unit currently producing
  logs. Populated from `label_values({job="systemd-journal"}, unit)` so
  it auto-refreshes from Loki. Default is "All". Pick one or more units
  (e.g. `qbittorrent.service`, `caddy.service`) to scope every panel to
  just those units. The "Top 10 units by error count" and the global
  error counters are intentionally **not** scoped to `$unit` — they are
  always system-wide so you can spot a noisy unit you forgot about.
- **`level`** — multi-select from a fixed list (`critical`, `error`,
  `warning`, `info`, `debug`, `unlabeled`). Default is
  `critical|error|warning`. Matches against the `level` Loki label set
  at ingestion time by Alloy, which parses `level=foo` (Go logfmt) and
  `[Foo]` (Serilog/AdGuard/celery) from each line and normalizes the
  result to one of the five canonical buckets. Lines without a
  recognized level word (HTTP access logs, redis bare text, .NET
  stack-trace continuation lines) are tagged `unlabeled` so the level
  filter can never silently hide them — pick `unlabeled` from the
  dropdown to see them.

To dig into a specific service: pick its unit, switch level to `info` to
see everything, widen the time range, then narrow back down once you've
found what you want.

## When you want depth

These dashboards intentionally cover the basics. For richer pre-built
views, import these from grafana.com (Dashboards → New → Import → enter
the ID, click Load):

- **1860 — Node Exporter Full** — the canonical exhaustive node_exporter
  dashboard. Per-CPU breakdowns, per-disk IO, per-interface network,
  pressure stall, hardware sensors, the works. Heavier than what's here
  but unbeatable for "where is the bottleneck."
- **13133 — ZFS (zfs_exporter v2)** — companion to the v2 zfs_exporter
  shipped here; deeper per-dataset breakdowns and ARC stats than the
  starter view.
- **20204 — SMART (smartctl_exporter)** — per-drive SMART attribute
  drill-downs (reallocated sectors, pending sectors, power cycles,
  workload) keyed off the same `smartctl_exporter` metrics. Pair with
  Scrutiny for the same data via two different lenses.

## Persistence and the role of this directory

These dashboards are imported via the Grafana UI rather than declaratively
provisioned, by deliberate decision (see the `theonecfg` notes). Once
imported, Grafana stores them in `/var/lib/grafana/grafana.db` on
`scheelite`, which is on the impermanence persistence list. Edits you
make in the UI persist across reboots and `nixos-rebuild` runs.

The JSON files in this directory are a **reference snapshot** from
initial import. They are not reapplied automatically — the live
dashboards in Grafana's DB are the source of truth, and edits in the
UI never need to be synced back here. Treat the files as:

- a known-good starting point you can re-import if a live dashboard
  gets broken or you want to start over,
- a learning reference for what a working query / panel structure
  looks like while you customize via the UI,
- a record of what the "v0" of these dashboards looked like before
  any tweaks.
