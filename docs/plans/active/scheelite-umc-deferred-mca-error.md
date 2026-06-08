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
  ~5-min MCE poller (identical `status`/`misc` each time, `Over` bit set;
  rasdaemon recorded a single distinct event). Rate of *new* corruption
  looks like ~0, not a storm.

## Assessment

A corrected-class UMC ECC error that appears on some cold boots but not
others is the classic signature of **marginal DDR5 memory** — most often
**EXPO/XMP overclock instability** (memory training is nondeterministic
across cold boots), sometimes an **early-degrading DIMM**. Not urgent
(deferred, "no action required", system stable), but a genuine
memory-subsystem signal that can progress — not a phantom and not
"benign uncore quirk" (an earlier pre-decode guess that the decode
corrected).

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

## DIMM labels (in progress)

Goal: have rasdaemon name the physical slot (e.g. `DIMM_A2`) instead of
"bank 31 / UMC". Prerequisites:

- `amd64_edac` must be loaded so EDAC enumerates the memory controllers —
  added via `hardware.rasdaemon.extraModules = [ "amd64_edac" ]` on
  scheelite (was not loaded; `ras-mc-ctl --layout` reported "No memories
  found via edac").
- After deploy, read `ras-mc-ctl --layout` + `sudo dmidecode -t memory`
  to map EDAC mc/channel → physical slot + part number, then populate
  `hardware.rasdaemon.labels` with headers matching the DMI strings
  (`ASUSTeK COMPUTER INC.` / `PRIME X670E-PRO WIFI`).
- Caveat: `amd64_edac` DIMM enumeration on Zen4 (Family 19h) is not
  guaranteed; if EDAC still finds no memories after loading the module,
  per-slot labels via EDAC won't be possible and we note the limitation.

## References

- `nixos-modules/services/rasdaemon/module.nix` — the wrapper (enable +
  record).
- `nixos-configurations/scheelite/default.nix` — `rasdaemon.enable` and
  `hardware.rasdaemon.extraModules`.
- `docs/plans/active/scheelite-cooling-and-thermals.md` — board/CPU/cooling context.
