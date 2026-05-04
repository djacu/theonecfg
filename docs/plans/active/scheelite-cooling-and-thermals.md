# scheelite cooling & thermals — investigation and remaining work

**Status:** Active (fan swap complete; HBA/expander cooling and `services.fancontrol` integration deferred)
**Started:** 2026-04-26
**Owner:** djacu
**Related:** `scheelite-homelab-services.md` (thermal stability is implicit prerequisite to running 24/7 services)

## Context

The scheelite chassis (Silverstone RM43-320-RS) shipped with stock 120×38mm fans on the drive backplanes that were extremely loud at all times. This document captures the investigation that diagnosed the noise source, the action taken, and the work that remains.

## Hardware reference

Confirmed via `dmidecode`, `lspci`, `lsscsi`, and direct inspection:

| Component | Model |
|---|---|
| Motherboard | ASUS PRIME X670E-PRO WIFI |
| CPU | AMD Ryzen 9 7950X (16C/32T, 170W TDP) |
| CPU cooler | Noctua NH-D12L (NF-A12x25r 120mm fan) |
| Chassis | Silverstone RM43-320-RS (4U, 20-bay) |
| Drives | 8× WDC Ultrastar DC HC530 14TB SAS (`WUH721414AL4204`) in raidz3 (`scheelite-tank0`) |
| HBA | LSI SAS9340-8i / IBM ServeRAID M1215 (Broadcom SAS3008 [1000:0097], `mpt3sas` IT-mode, FW 16.00.12.00) |
| SAS expander | Adaptec AEC-82885T 36-port SAS-3 12Gbps |
| Boot | 2× Samsung 990 PRO 2TB NVMe (mirrored swap, ZFS root with impermanence) |
| Super-I/O | Nuvoton NCT6799D-R (chip ID `0xd802`) |

## Cooling layout

| Position | Fan | Connection | Control |
|---|---|---|---|
| CPU cooler | 1× Noctua NF-A12x25r | CPU_FAN | BIOS Q-Fan |
| Rear exhaust | 2× Noctua NF-A8 PWM (chained) | CHA_FAN2 | BIOS Q-Fan |
| Middle wall (drive cage push) | **3× Noctua NF-F12 industrialPPC-3000 PWM** (replaced stock CC12038H12D — see below) | Drive backplane PWM headers | **Backplane autonomous controller** |
| HBA heatsink | *not yet installed* | (planned: CHA_FAN1) | (planned: BIOS Q-Fan / fancontrol) |
| Expander heatsink | *unknown* (factory may or may not include one) | TBD | TBD |

## Key findings

### 1. The drive backplanes are autonomous fan controllers

Per the official `RM22-308_RM22-312_RM43-320-RS-4bay_SAS_backplane_User_Guide-v2.pdf`:

- Each backplane PCB has its own onboard thermal sensor + 6× 4-pin PWM fan headers + autonomous fan controller.
- Control law: first 5s of boot @ 80% PWM duty; after, linear 30% (sensor \<25°C) → 99% (sensor >45°C).
- Fan-failure failsafe: if a previously-spinning fan stops, all fans on that backplane go to 100% until reboot. (Power-on autodetect skips empty connectors, so no failsafe trip from never-populated headers.)
- Per the chart for RM43-320-RS: 0% duty → ~1000 RPM, 30% → ~1900 RPM, 50% → ~2500 RPM, 100% → ~4000 RPM (with stock fans).
- **There is no PWM input from the motherboard to the backplane.** The backplane is uncontrollable from BIOS, kernel, or `fancontrol` daemon.

### 2. Linux fan control IS available on the motherboard side (just not for backplane fans)

- Mainline `nct6775` kernel driver supports the Nuvoton NCT6799D-R when loaded with `modprobe nct6775 force_id=0xd802`. Kernel 6.15.11 was sufficient — no kernel upgrade required.
- `lm_sensors 3.6.0` userspace `sensors-detect` does not auto-identify chip ID `0xd802` (its chip database is older); the kernel module is the path forward, not the userspace database.
- Once loaded, the chip exposes 7 PWM channels and 7 fan tachs via `/sys/class/hwmon/hwmonN/pwm{1..7}` and `fan{1..7}_input`.
- Currently visible motherboard fans: `fan2` (CPU_FAN, NF-A12x25r) and `fan3` (CHA_FAN2, the NF-A8 chain). All other channels read 0 RPM (nothing connected).
- `asus-ec-sensors` (`asusec-isa-0000`) module is also present — reads CPU/MB/VRM/CPU_Opt temps via the EC, but does not expose PWM control.

### 3. SES on the AEC-82885T does not surface telemetry

Per `sg_ses --join` against the enclosure at `/sys/class/enclosure/0:0:8:0`:

- Element types are declared (3 temperature sensors, 5 cooling fans, 3 voltage sensors, SAS expander) but every element reports `status: Unsupported` with `Temperature: <reserved>` / `Actual speed=0 rpm` / `Voltage: 0.00 Volts`.
- The expander's firmware doesn't populate any of the diagnostic data, so SES is a dead end for backplane temps, expander chip temp, or expander fan speed.
- SES does correctly enumerate the 24 array-device slots and show drive presence, SAS addresses, and slot indices (slots 8–15 currently populated; slots 16–23 "Not installed").

### 4. Stock fan specifications (CC12038H12D)

The stock middle-wall fans are OEM'd from CoolCox by Silverstone. From the [CoolCox CC12038 family datasheet](https://www.coolcox.com/products/pdf/CC12038_B.pdf):

| Spec | Value |
|---|---|
| Size | 120 × 120 × 38 mm |
| Speed | 4000 ±10% RPM |
| Airflow | 193.5 CFM |
| Static pressure | 17.0 mmH₂O |
| Noise | 59.0 dBA |
| Power | 20.4 W (1.70 A @ 12 V) |
| Bearing | Dual ball |

The CC12038 family also has L (3000 RPM, 140 CFM, 10 mmH₂O, 50 dBA) and M (3500 RPM, 152 CFM, 13.7 mmH₂O, 55 dBA) speed bins; Silverstone shipped the H (high-speed) bin. These are designed for datacenter ambient and sustained max-load operation.

### 5. Replacement fan choice and rationale

Installed: **3× Noctua NF-F12 industrialPPC-3000 PWM**.

| Spec | NF-F12 iPPC-3000 PWM | vs. stock |
|---|---|---|
| Size | 120 × 120 × 25 mm | -13 mm thickness |
| Speed | 3000 RPM | -25% |
| Airflow | 109 CFM | -44% |
| Static pressure | 7.63 mmH₂O | -55% |
| Noise | ~43.5 dBA | -16 dBA |
| Power | 3.6 W (0.30 A) | -83% per fan |
| Bearing | SSO2 magnetic-FDB (150,000 h MTTF) | longer life than ball |

Why this fan over alternatives:

- **NF-A12x25 PWM**: too low static pressure (2.34 mmH₂O) for a packed drive cage with cabling restriction.
- **Phanteks T30 (30mm thick)**: closer thickness match but lower static pressure (3.81 mmH₂O); not the right tool for dense drive cages even though it's excellent for radiators.
- **Sunon PSD1212PMB1-A.GN (38mm match)**: true thickness, ~$25, but ~38 dBA noise vs Noctua's 30 dBA at typical duty — gives up the noise win for a thickness match that's purely cosmetic.
- **CC12038L12D (stock family, low bin)**: 3000 RPM, 140 CFM, 10 mmH₂O, **50 dBA** — same airflow class as Noctua but +6.5 dBA noise. Loses on noise-per-CFM.

The 25mm thickness mismatch in the 38mm-deep mounting frame is functionally invisible — fan sits recessed, "missing" depth becomes empty air, no airflow penalty.

The stock CC12038H12D set was retained as spares, labeled "RM43 spares — for hot ambient or garage relocation."

### 6. Validation results

Methodology: 1 hour idle settle at 26.5°C ambient (AC-conditioned home), then `sensors` and `smartctl -A` on each drive. Comparison vs. equivalent measurements with stock fans the day before swap.

| Sensor | Stock fans | NF-F12 iPPC-3000 | Δ | Limit |
|---|---|---|---|---|
| Drive average | 30.5°C | 39.6°C | +9.1 | 60°C op / 85°C trip |
| Drive range | 30–31°C | 38–41°C | — | — |
| NVMe-0 composite | 33.9°C | 44.9°C | +11 | 81.8°C alarm / 84.8°C crit |
| NVMe-0 sensor 2 | 35.9°C | 50.9°C | +15 | — |
| DIMMs (×4) | 31°C | 38–40°C | +7–9 | 55°C high / 85°C crit |
| VRM | 41°C | 48°C | +7 | ~110°C |
| CPU Tctl | 39.5°C | 42.8°C | +3 | 95°C |
| Motherboard | 29°C | 33°C | +4 | — |
| CPU_FAN RPM | 660 | 779 | +119 | — |
| CHA_FAN2 RPM | 662 | 785 | +123 | — |

All sensors well within safe limits. Drive temps in the 38–41°C range are squarely in the failure-rate "flat zone" documented by Backblaze and Google's drive-failure studies (25–50°C → no measurable lifespan impact).

The motherboard-zone temp rise (NVMe, DIMMs, VRM) is the chassis airflow side-effect: the new fans push less total air through the middle wall, so less air enters the motherboard zone before being pulled out by the rear NF-A8 PWMs. Still safe; flagged as a watch item if heavy CPU load is added later.

User confirmed audible result: "much quieter."

## Work remaining

### High priority — when convenient

1. **Install Noctua NF-A4x20 PWM on the HBA (SAS3008) heatsink.**

   - Mount via zip-ties through heatsink fin slots, or 3M Dual Lock to an adjacent surface (not on the heatsink itself).
   - Orient airflow into the fin stack.
   - Plug into CHA_FAN1 (currently free).
   - BIOS Q-Fan curve (interim): 30% below 50°C, 60% at 60°C, 90% at 70°C, 100% at 80°C, source = motherboard temp (or CPU temp).
   - Slightly more important post-fan-swap than before: with NF-F12 iPPC-3000s pushing less air through the chassis, the motherboard zone runs warmer (NVMe 51°C, DIMMs 40°C, VRM 48°C) and an HBA fan adds local airflow that incidentally helps that zone too.

1. **Verify expander cooling.**

   - Trace SFF-8643 cable from HBA to find the AEC-82885T physical board location.
   - Visual check: factory 40mm fan present?
     - If yes: no action.
     - If no: add second NF-A4x20 PWM on CHA_FAN3.
   - SES does not provide expander temp, so this is inspection-only — no Linux-side telemetry available.

### Medium priority — validation tasks

3. **Sustained-load thermal test.**

   - Run `sudo zpool scrub scheelite-tank0`.
   - After ~30 min of sustained activity, re-measure drive temps (script below).
   - Acceptance: any drive >45°C suggests airflow issue with that bay; below 45°C is full margin.
   - Expected with current setup (8 drives, 26.5°C ambient): 42–46°C mid-scrub.

1. **Re-check the two drives with prior ECC delayed rereads.**

   - sdc (serial `9MGT43JU`) had 2 delayed corrections in 46 GB scanned.
   - sdh (serial `9MGSWRNU`) had 3 delayed corrections in 61 GB scanned.
   - Re-run the SAS SMART error counter check; counts should be flat or only marginally higher. Significant growth would indicate developing weak spots.

### Low priority — nix integration

5. **Persist `nct6775` and `sg` kernel modules in scheelite config.**

   Add to `nixos-configurations/scheelite/default.nix` (or a new `nixos-modules/hardware/sensors/module.nix` wrapping it):

   ```nix
   boot.kernelModules = [ "nct6775" "sg" ];
   boot.extraModprobeConfig = ''
     options nct6775 force_id=0xd802
   '';
   environment.systemPackages = with pkgs; [ lm_sensors sg3_utils smartmontools ];
   ```

   - `nct6775` enables motherboard fan/temp/PWM via `/sys/class/hwmon/`.
   - `sg` enables `/dev/sg*` for SES queries (`sg_ses`, `lsscsi -g`, etc.).
   - `lm_sensors` brings the `sensors` command into PATH without a `nix-shell` wrapper.

1. **Configure `services.fancontrol` for the motherboard-controllable fans.**

   - Once HBA fan is installed and verified working.
   - Run `pwmconfig` interactively on scheelite to map PWM channels to fans (the tool sweeps each PWM channel and asks which fan stops).
   - Generate `/etc/fancontrol` (or pass via `services.fancontrol.config`).
   - Wrap in a NixOS module: `nixos-modules/hardware/fancontrol/module.nix`.
   - **Cannot control:** the 3 backplane fans (autonomous, not motherboard-visible).
   - **Can control:** CPU_FAN, CHA_FAN2 (rear NF-A8 chain), CHA_FAN1 (planned HBA fan), CHA_FAN3 (potential expander fan).
   - Drive curves off the appropriate sensor: `k10temp` Tctl for CPU fan, motherboard / `AUXTIN0` (PCH) for chassis fans.

### Deferred — not urgent

7. **Investigate `sas3ircu` packaging** if HBA chip telemetry becomes desired. Broadcom proprietary tool, not in nixpkgs; would need a custom nix expression. Low value while dmesg stays clean.
1. **Q-Fan curve adjustments** for the rear NF-A8 PWMs to compensate for reduced supply airflow if motherboard-zone temps drift further upward under heavy CPU load. Not needed at idle.
1. **Clear the chassis intrusion alarm** (`intrusion0: ALARM` from earlier sensor output) once the case is closed and stable: `echo 0 | sudo tee /sys/class/hwmon/hwmonN/intrusion0_alarm` (where `N` is the `nct6799-isa-0290` instance).

## Dead ends and non-issues

- **Loud fans were not a Linux/nix problem.** Pure hardware: stock high-RPM fans + autonomous backplane control law. Confirmed before any nix work was attempted.
- **Linux cannot control the 3 backplane fans.** They are autonomous — no PWM input from the motherboard exists. Confirmed via the official Silverstone backplane manual.
- **SES does not provide backplane or expander temperature.** Element types declared but all `Unsupported` on the AEC-82885T. Indirect monitoring (drive temps, dmesg quiet) is the only signal.
- **HBA chip temperature is not directly readable** by standard tools (mpt3sas sysfs / smartctl / IT-mode storcli). `sas3ircu` could read it but is non-trivial to package.
- **Front-panel LEDs flickering green/red on a populated bay** is the manual's "Detect HDD" state — yellow solid + green blinking + red blinking simultaneously, perceived as alternation. Caused by background medium scan + occasional ECC delayed reads on a brand-new array. ZFS, kernel log, and SMART overall-health all confirmed clean. Not a fault.

## Diagnostic command reference

For when this is revisited. All commands assume fish shell at `djacu@scheelite ~>`. The current scheelite config does not auto-load `nct6775` or `sg`, so module loads are needed each session until step (5) above is completed.

```fish
# Drive temperatures (uses bash inside nix-shell to avoid fish glob quirks)
sudo nix-shell -p smartmontools --run 'for d in /dev/sd[a-h]; do echo -n "$d: "; smartctl -A "$d" | grep "Current Drive Temperature"; done'

# Full SAS SMART health (error counters, defects, scan status)
sudo nix-shell -p smartmontools --run 'for d in /dev/sd[a-h]; do echo "=== $d ==="; smartctl -H -A -l error -l background "$d" | grep -iE "health|status|errors|pending|reallocat|defect|uncorrect|verify|grown|non-medium|self-test"; done'

# All system sensors
sudo nix-shell -p lm_sensors --run sensors

# Motherboard fan tachs (load nct6775 first, with force_id)
sudo modprobe nct6775 force_id=0xd802
for f in /sys/class/hwmon/hwmon*/fan*_input
  echo "$f: "(cat $f)" RPM"
end

# SES enclosure inventory + drive bay → /dev/sd mapping
sudo modprobe sg
sudo nix-shell -p lsscsi --run 'lsscsi -g'
set sg_name (ls /sys/class/enclosure/0:0:8:0/device/scsi_generic/ | head -1)
sudo nix-shell -p sg3_utils --run "sg_ses --join /dev/$sg_name"

# ZFS pool status
zpool status -v scheelite-tank0

# HBA / SCSI errors in kernel log
sudo journalctl -k --since "1 hour ago" | grep -iE "sd[a-h]|mpt3sas|sas|error|fault|reset|retry"

# Map drive serial → /dev/sd (useful for bay identification)
for d in /dev/sda /dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf /dev/sdg /dev/sdh
  printf '%s -> ' $d
  sudo nix-shell -p smartmontools --run "smartctl -i $d" | grep -iE "serial|product"
end
```

## References

- [Silverstone RM22-308/RM22-312/RM43-320-RS 4-bay SAS backplane User Guide v2 (PDF)](https://www.silverstonetek.com/upload/downloads/Manual/case/RM22-308_RM22-312_RM43-320-RS-4bay_SAS_backplane_User_Guide-v2.pdf)
- [CoolCox CC12038 family datasheet (PDF)](https://www.coolcox.com/products/pdf/CC12038_B.pdf)
- `docs/plans/active/scheelite-homelab-services.md` — broader scheelite plan
- Memory: `project_scheelite_hardware.md`
