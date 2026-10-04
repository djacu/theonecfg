# ilmenite standby power

**Status:** Complete
**Date:** 2026-10-04
**Owner:** djacu
**Context:** Task 8 of `docs/plans/active/ilmenite-laptop-bringup-implementation.md`

## Question

What does the Framework Laptop 13 Pro (Intel Core Ultra Series 3) do when the
lid closes on battery under the default Plasma configuration, and does the
firmware resume bug reported for BIOS 3.02 (FrameworkComputer/SoftwareFirmwareIssueTracker#274)
reproduce here?

## Setup

- BIOS 03.02, kernel 6.18.49, `mem_sleep` offers only `s2idle`.
- Plasma 6 defaults: lid close sleeps. No power tuning applied.
- Battery `BAT1`, `charge_full` 4737 mAh at about 17.4 V, so 1% of charge is
  roughly 0.82 Wh.
- Measurement: `docs/investigations/ilmenite-standby-measure.sh` run as
  `djacu` immediately before closing the lid and immediately after logging
  back in. Each scenario slept about 30 minutes on battery. Residency comes
  from `/sys/kernel/debug/pmc_core/slp_s0_residency_usec` and
  `substate_residencies`; drain from `BAT1/charge_now`.

## Results

| Scenario                     | Asleep  | Charge drop | Drain    | Average draw | S0ix residency (of sleep) | Deepest substate reached        | BERT / reboot |
| ---------------------------- | ------- | ----------- | -------- | ------------ | ------------------------- | ------------------------------- | ------------- |
| A: nothing plugged in        | 31m 59s | 13 mAh      | 0.51 %/h | 0.43 W       | 100%                      | S0i2.2 for 1916 s               | none          |
| B: expansion cards installed | 30m 45s | 13 mAh      | 0.54 %/h | 0.44 W       | 99.9%                     | S0i2.2 for 1841 s               | none          |
| C: USB-C hub with Ethernet   | 30m 27s | 36 mAh      | 1.50 %/h | 1.23 W       | 99.8%                     | S0i2.1 for 1823 s, S0i2.2 never | none          |

All three sleeps resumed on the first lid open. The journal shows matching
`PM: suspend entry (s2idle)` and `PM: suspend exit` pairs, the boot id was
the same before and after every scenario, and no BERT record exists in any
boot. The firmware reset in issue #274 did not reproduce in three attempts.

Raw deltas, for anyone redoing the arithmetic:

| Scenario | Wall clock | `slp_s0` delta | `charge_now` before → after | Voltage before → after |
| -------- | ---------- | -------------- | --------------------------- | ---------------------- |
| A        | 1946 s     | 1920.1 s       | 4392 → 4379 mAh             | 17.474 → 17.466 V      |
| B        | 1859 s     | 1842.6 s       | 4369 → 4356 mAh             | 17.454 → 17.430 V      |
| C        | 1842 s     | 1823.8 s       | 4351 → 4315 mAh             | 17.405 → 17.371 V      |

## Reading

- **s2idle works and is cheap on this machine.** Unplugged, the SoC spends
  the entire sleep in the deepest substate the PMC reports (S0i2.2) and the
  system draws under half a watt. At 0.5 %/h a full battery lasts about
  eight days asleep.
- **Expansion cards cost nothing measurable.** Scenario B is within noise
  of A, and the substate profile is identical.
- **The USB-C hub with Ethernet triples standby draw.** With it attached the
  SoC never enters S0i2.2 and sits in S0i2.1 for the whole sleep. Draw rises
  to 1.2 W and drain to 1.5 %/h, about 2.8 days from full. Residency is still
  99.8%, so the hub does not block S0ix; it holds the platform in a shallower
  substate. Which part of the hub does it (the Realtek Ethernet, the hub
  controller, or a device left plugged into it) was not separated in this
  pass.
- **powertop** (60 s, idle, lid open, Firefox and Plasma running, 23%
  backlight) reported 4.25 W discharge and about 1250 wakeups/s, led by the
  scheduler tick, the `i2c_designware.5` interrupt that serves the i2c-hid
  touch devices, and Firefox. Nothing in the device list stood out as a
  standby offender, and the figure is an awake baseline, not a sleep one.

The `s0ix_blocker` file lists cumulative status counters rather than
per-sleep blockers; its values grew across all three runs and did not single
out a device, so the substate residency was the decisive signal.

## Recommendation

Keep Plasma's default lid-to-sleep behaviour; no configuration change is
needed. For long unattended periods on battery, unplug the hub; expansion
cards can stay. Hibernation remains out of scope, so the fallback for very
long periods is a shutdown.

## Follow-ups (not started)

- Separate the hub's components: repeat scenario C with only the Ethernet
  card, only the bare hub, and only a USB stick, to find what holds S0i2.1.
- Re-run scenario A after the next BIOS update to check that the S0i2.2
  behaviour and the clean resume persist.
- If a resume ever fails: `journalctl -b -1 -k | tail` for a missing
  `suspend exit`, and `journalctl -b -k | grep BERT`, then set Plasma's lid
  action to lock until a firmware fix ships.
