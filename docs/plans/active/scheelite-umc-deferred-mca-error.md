# scheelite — recurring UMC deferred MCA error

Status: open / investigating
Owner: dan
Last updated: 2026-06-07

## Symptom

On scheelite's console, a `[Hardware Error]` block recurs roughly every
5½ minutes (99 in the current boot). Every instance is byte-identical:

```
mce: [Hardware Error]: Machine check events logged
[Hardware Error]: Deferred error, no action required.
[Hardware Error]: CPU:0 (19:61:2) MC31_STATUS[Over|-|MiscV|-|PCC|-|-|CECC|Deferred|Poison|-]: 0xca0158a452cc2420
[Hardware Error]: IPID: 0x8234c5c7b783be99
[Hardware Error]: cache level: RESV, tx: INSN
```

## Decode (via rasdaemon)

rasdaemon (`hardware.rasdaemon`, enabled 2026-06-07) decoded it
authoritatively:

```
Unified Memory Controller V2 (bank=31), status=ca0158a452cc2420,
Deferred error, no action required.,
mci=Error_overflow Processor_context_corrupt CECC Poison consumed,
cpu_type=AMD Scalable MCA, cpu=0, socketid=0,
ipid=8234c5c7b783be99, microcode=a60120a
```

- **Failing unit: the Unified Memory Controller (UMC)** — the on-die
  DRAM controller, *not* a CPU cache (the kernel's "cache level: RESV"
  line is a red herring for this bank).
- Class: `CECC` = corrected ECC, deferred, with a poisoned cacheline.
  Kernel grades it **"no action required."**

## Key evidence: new this boot, no software delta

| boot                                   | window                         | Hardware-Error lines |
| -------------------------------------- | ------------------------------ | -------------------- |
| 0 (current, since 2026-06-07 19:40:49) | post-reboot after 26.11 deploy | 99                   |
| −1 (2026-06-01 → 2026-06-07, ~6 days)  | the long pre-reboot run        | 0                    |
| −2, −3                                 | earlier                        | 0                    |

- Kernel (`6.18.33`) and microcode (`0x0a60120a`) are **identical**
  across boot −1 and boot 0. So this is **not** a new kernel/microcode
  surfacing a previously-masked event.
- The only change between the clean 6-day boot and this one is **the
  reboot itself** → the BIOS re-trained the memory, and this boot landed
  in a state where a UMC channel logs a deferred ECC error.
- The 99 journal lines are **one latched event re-read** by the kernel's
  ~5-min MCE poller (`Over` bit set). Rate of *new* corruption looks like
  ~0, not a storm.

### Trend (rasdaemon, confirms "latched, not accumulating")

rasdaemon recorded 8 MCE events over ~38 min (21:24:37 → 22:02:50), one
per ~5½-min poll cycle. **Every field is byte-identical across all 8**,
crucially including the syndrome/address `misc=0x5c184e92a34a3dc2`
(alongside `status=0xca0158a452cc2420`, bank 31). A genuinely recurring
fault would vary the `misc`/syndrome between events; an unchanging one is
the same latched entry being re-polled. So over 38 minutes there is **one
latched error, zero new distinct events** — the reassuring end of the
range (latched at this boot's training, not actively degrading), pending
the reboot test below.

## Memory in this host

G.Skill Flare X5 32GB (2×16GB) DDR5-6000 CL36, kit
`F5-6000J3636F16GX2-FX5` — **non-ECC** consumer DDR5 running its
**EXPO** profile (DDR5-6000 is an overclock relative to JEDEC; 6000 CL36
is the AM5 2-DIMM sweet-spot speed, so not aggressive).

## Assessment

A corrected-class UMC ECC error that appears on some cold boots but not
others is the classic signature of **marginal DDR5 memory** — most often
**EXPO overclock instability** (memory training is nondeterministic
across cold boots), sometimes an **early-degrading DIMM**. The confirmed
EXPO DDR5-6000 kit supports that hypothesis directly. Because 6000 CL36
is the sweet-spot speed (not an aggressive OC), suspicion leans toward a
slightly-weak kit, SoC/VDDG/VDDP voltage, or an AGESA revision rather
than a reckless overclock. Not urgent (deferred, "no action required",
system stable), but a genuine memory-subsystem signal that can progress —
not a phantom and not "benign uncore quirk" (an earlier pre-decode guess
that the decode corrected).

## Diagnosis plan

1. **Reboot and re-check.** If errors vanish on the next cold boot →
   training-variance/marginality (intermittent across boots). If they
   persist every boot → more likely a specific failing DIMM.
1. **memtest86+** — several full passes. The definitive RAM health test.
1. **BIOS memory settings** — is EXPO/XMP on, at what speed? Highest-value
   diagnostic: disable EXPO (or drop one speed grade) and see if the
   errors stop. Check for a newer AGESA/BIOS for the PRIME X670E-PRO WIFI
   (Zen4 memory-training stability improved across AGESA revisions).
1. **Trend via rasdaemon** — periodically `ras-mc-ctl --errors`; watch
   whether distinct events accrue (active degradation) or it stays one
   latched entry (marginal-but-stable).

## DIMM labels: not achievable on this hardware

Goal was to have rasdaemon name the physical slot (e.g. `DIMM_A2`)
instead of "bank 31 / UMC". **Not possible here**, conclusively:

- Per-slot labels need `amd64_edac` to enumerate the memory controllers
  into EDAC. On scheelite `sudo modprobe amd64_edac` fails with
  **`No such device` (ENODEV)** — the driver finds no ECC-capable memory
  controller to bind to.
- That's expected: the RAM is **non-ECC** (G.Skill Flare X5). EDAC is
  built around ECC reporting, so with non-ECC DIMMs there is no topology
  for it to expose and `ras-mc-ctl --layout` stays "No memories found via
  edac". There is no BIOS ECC toggle to flip (non-ECC modules).
- The `extraModules = [ "amd64_edac" ]` line that was briefly added to
  scheelite was reverted — a module that can't bind is just a failed
  `modprobe` at every boot.

Attribution therefore stops at the MCA decode rasdaemon already gives
(`Unified Memory Controller V2`, bank 31). Narrowing to a specific
DIMM is done physically instead: memtest86+ per-DIMM, or pull/swap one
stick at a time (the diagnosis plan above).

## References

- `nixos-modules/services/rasdaemon/module.nix` — the wrapper (enable +
  record).
- `nixos-configurations/scheelite/default.nix` — `rasdaemon.enable`.
- `docs/plans/active/scheelite-cooling-and-thermals.md` — board/CPU/cooling context.
