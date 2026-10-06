# ilmenite hibernate firmware test

**Status:** Complete. Passed, 3 of 3 cycles (2026-10-04)
**Date:** 2026-10-04
**Owner:** djacu
**Context:** Gate for the ilmenite suspend-then-hibernate design. Decided
2026-10-04: if this passes, ilmenite is reinstalled with LUKS swap (68 GB) and a
LUKS-wrapped pool so one passphrase covers cold boot and resume.

## Question

Does the Framework Laptop 13 Pro (Intel Core Ultra Series 3, BIOS 03.02) enter
ACPI S4 and come back from a hibernation image?

A community report on this board and BIOS
(<https://community.frame.work/t/fw13-pro-suspend-then-hibernate-system-crash-possible-firmware-issue-s2idle-resume-platform-resets-panther-lake-bios-3-02/84960>,
2026-09-20) saw resume fail with
`ACPI BIOS Error (bug): Could not resolve symbol [\_WAK.G4], AE_NOT_FOUND`,
thousands of follow-on ACPI errors, the battery device gone, and recovery only
after an EC reset. Framework lists a single BIOS for this mainboard, 03.02
(2026-06-05), at <https://resources.frame.work/downloads/laptop-13-pro/intel-core-ultra-3/>.
That is separate from the s2idle reset in
FrameworkComputer/SoftwareFirmwareIssueTracker#274, which did not reproduce in
`ilmenite-standby-power.md`.

## Why the installer stick

- The installed system cannot hibernate today: the ZFS module puts
  `nohibernate` on the kernel command line and the swap is keyed randomly on
  every boot. Testing there would require the real layout change first.
- The live ISO never imports the ZFS pool, so the hibernation image holds only
  the installer's memory. No pool keys and no personal data are written to
  disk.
- The image goes to the existing 32 GB swap partition,
  `/dev/disk/by-partlabel/disk-disk1-swap`. The installed system treats that
  partition as scratch: on every boot it opens it with a fresh random key and
  runs `mkswap` on the mapping, with no signature check on the raw partition
  (nixpkgs `nixos/modules/config/swap.nix`, `mkswap-*` service). Its command
  line keeps `nohibernate`, so its kernel never attempts a resume from whatever
  the partition holds.
- Hibernation is triggered through sysfs, not systemd. systemd's path would
  also write the `HibernateLocation` EFI variable, which the installed
  system's initrd would act on at the next boot. The sysfs path writes nothing
  outside the swap partition.
- Resume is also triggered from userspace. The ISO's scripted stage 1 only
  resumes from devices baked in at build time, so a `resume=` edit would do
  nothing. The kernel accepts a `major:minor` write to `/sys/power/resume` at
  any time after boot and runs the same `software_resume()` an initrd would
  (`kernel/power/hibernate.c`).

## Preconditions

- Secure Boot off. Already the case; the stick needs it.
- The stick: `nixos-minimal-26.05.889.b51242d7d436-x86_64-linux`. Its GRUB menu
  has two installer entries. "Linux LTS" boots 6.18.33 with `nohibernate` on
  its command line and has ZFS. "Linux 7.0.10" has no ZFS and therefore no
  `nohibernate`. Use the LTS entry with the word removed, since ilmenite runs
  the 6.18 series. The 7.0.10 entry is the fallback data point.
- AC and the USB-C hub with Ethernet connected, so argentite can reach the
  live system. Logs on the live system vanish at power off, and the display
  may not come back right away after a resume.
- The stick in a port on the laptop itself, not in the hub. The live root
  filesystem is the squashfs on the stick, so unplugging the hub with the
  stick in it kills the session with `SQUASHFS error` lines on the console.
  Recover with `echo b > /proc/sysrq-trigger` and start the cycle again.

## Procedure

Commands marked (argentite) run in fish on argentite. Commands marked (live)
run as root on the live system and avoid shell-specific syntax.

### Cycle 1

1. Boot the stick. In GRUB, highlight `NixOS ... Installer (Linux LTS)`, press
   `e`, find the line starting with `linux`, delete the word `nohibernate`,
   then press `Ctrl-x` to boot.

1. (live) Set a root password and find the address:

   ```sh
   sudo -i
   passwd
   ip -br addr
   ```

1. (argentite) Open a session. The live host key changes on every boot, so do
   not record it:

   ```fish
   set ip 10.0.10.80
   alias lssh 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$ip'
   lssh
   ```

1. (live) Confirm hibernation is allowed and the firmware advertises S4:

   ```sh
   grep -c nohibernate /proc/cmdline
   cat /sys/power/state
   cat /sys/power/disk
   ```

   Expected: `0`, then `freeze mem disk`, then a line containing `platform`
   (the mode in brackets is the current one). No `platform` means the firmware
   does not offer S4 to this kernel. Stop and record that.

1. (live) Make sure the right partition is about to be used, then make it a
   plain swap and activate it. Only the 32G partition labelled
   `disk-disk1-swap` may be touched:

   ```sh
   lsblk -o NAME,SIZE,PARTLABEL /dev/nvme0n1
   mkswap -L hibtest /dev/disk/by-partlabel/disk-disk1-swap
   swapon /dev/disk/by-partlabel/disk-disk1-swap
   swapon --show
   ```

1. (live) Leave a marker that only a real resume preserves, and note the boot
   time:

   ```sh
   date -u > /run/hibtest-marker
   cat /run/hibtest-marker
   cat /proc/uptime
   ```

1. (argentite) Save the pre-hibernate kernel log:

   ```fish
   lssh dmesg > ~/hibtest-1-pre-dmesg.txt
   ```

1. (live) Hibernate through sysfs:

   ```sh
   echo platform > /sys/power/disk
   echo disk > /sys/power/state
   ```

   Expected: screen off within seconds, brief disk activity, then a complete
   power off (power LED off). Note how long it takes. If it has not powered
   off after two minutes, hold the power button and record that as a failure
   of type (a) below.

1. Press power. In GRUB, make the same edit on the same entry and boot. Do
   not run `swapon` or anything else on the swap partition before the resume.

1. (live, as root) Confirm the image is there:

   ```sh
   hexdump -C -s 4086 -n 10 /dev/disk/by-partlabel/disk-disk1-swap
   ```

   The ten bytes at that offset are the swap magic. Expected: `S1SUSPEND`.
   `SWAPSPACE2` means no image was written; record and stop the cycle. Random
   bytes mean the partition was rewritten since the hibernate, most likely by
   a normal boot of the installed system in between. `blkid` is not reliable
   here: on the first run it printed nothing for a partition that did hold an
   image.

1. (live) Resume from userspace:

   ```sh
   lsblk -dno MAJ:MIN /dev/disk/by-partlabel/disk-disk1-swap | tr -d ' ' > /sys/power/resume
   ```

   Expected: the console stops, the kernel prints `PM:` messages, and the
   earlier session reappears with its shell prompt. If the write returns and
   the fresh session is still there, read `dmesg | tail -n 30`; the kernel
   says why (for example "Image not present or could not be loaded").

1. (argentite) Open a new session (the old TCP connection will not have
   survived) and collect the post-resume state:

   ```fish
   lssh 'cat /run/hibtest-marker; cat /proc/uptime; ls /sys/class/power_supply; cat /sys/class/power_supply/BAT1/status' > ~/hibtest-1-post-state.txt
   lssh dmesg > ~/hibtest-1-post-dmesg.txt
   grep -i -E 'ACPI (BIOS )?Error|_WAK|BERT|Hardware Error|hibernat|PM: ' ~/hibtest-1-post-dmesg.txt | head -n 60
   ```

   The cycle passes if the marker shows the time from step 6, `/proc/uptime`
   is larger than a fresh boot would give, `BAT1` is listed, there are no `ACPI BIOS Error` lines, and display, keyboard, and Ethernet work.

### Cycles 2 and 3

Continue from the resumed session. Swap is still active and the kernel
restored the swap signature when it read the image, so repeat steps 6 to 12
twice more, numbering the files `hibtest-2-*` and `hibtest-3-*`. The same GRUB
edit is needed on every boot.

Run cycle 3 on battery with the hub unplugged, since that is the real use
case and the firmware takes a different path with no external power and no
dock: unplug the hub after writing the marker, keep it unplugged through the
power-on and the resume, and plug it back in only for the checks. The stick
must be in a laptop port for this (see Preconditions). If a session is ever
broken, hibernating it anyway leaves a useless image on the partition; in the
next fresh session run the `mkswap` from step 5 again, which wipes the old
`swsuspend` signature, and start the cycle over.

### After the last cycle

1. (live) Remove the plain swap signature so nothing on the raw partition can
   be mistaken for an image later:

   ```sh
   swapoff /dev/disk/by-partlabel/disk-disk1-swap
   wipefs -a /dev/disk/by-partlabel/disk-disk1-swap
   poweroff
   ```

1. Boot ilmenite normally and check that swap came up as before:

   ```fish
   swapon --show
   ```

   Expected: one `/dev/mapper/dev-disk-by...swap` entry, 32G.

### If a cycle fails

Four distinct failures, in order of where they happen:

- (a) Never powers off after `echo disk`. Kernel or firmware cannot enter S4.
- (b) Powers off, but the next boot shows `TYPE="swap"`, not `swsuspend`. The
  image was not written.
- (c) `swsuspend` present, but the resume write returns with the fresh session
  intact and dmesg reports a loading problem. Kernel-side.
- (d) Resume starts and the machine resets, stays dark, or the session returns
  with `ACPI BIOS Error ... _WAK` lines and `BAT1` missing. This is the
  firmware fault from the community report.

For (d), the report's recovery was: unplug every USB-C device, hold the power
button for about 30 seconds, release, then power on. If the installed system
later shows no battery device, repeat the reset. In all cases, save the dmesg
of the boot that followed the failure as `~/hibtest-N-fail-dmesg.txt`, then run
one cycle on the `Linux 7.0.10` entry (no GRUB edit needed). If 7.0 resumes and
6.18 does not, the problem is kernel-side and the design can pin a kernel. If
both fail the same way, it is BIOS 03.02 and the design waits for a BIOS
update.

## Results

| Cycle | Kernel  | Powered off after | Image present | Resumed | ACPI errors | BAT1 present | Notes                                                                                                                                                                                                                               |
| ----- | ------- | ----------------- | ------------- | ------- | ----------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | 6.18.33 | ~5 s              | yes           | yes     | none        | yes          | AC + hub. Image 621599 pages (2.4 GB), written at 2968 MB/s. Display back after a one-second flicker. One driver error on restore: `spd5118 0-0050` (DDR5 SPD sensor) `-6`. Bluetooth re-initialised. Marker and uptime continuous. |
| 2     | 6.18.33 | ~5 s              | yes           | yes     | none        | yes          | AC + hub, from the resumed session. Same `spd5118` `-6` on restore, nothing else. Marker and uptime continuous. Fresh ISO boots and the restored session each pulled a new DHCP lease (.80, .84, .85).                              |
| 3     | 6.18.33 | ~5 s              | yes           | yes     | none        | yes          | Battery, hub (AC + Ethernet) unplugged from before the hibernate until after the resume, stick in a laptop port. Fresh session. Same `spd5118` `-6` on restore, nothing else. Marker and uptime continuous.                         |

## Decision

Pass: three of three cycles resume on 6.18.33 with no ACPI BIOS errors and the
battery device present. Then the design proceeds (LUKS swap plus LUKS pool,
reinstall via `docs/runbooks/install-laptop-with-nixos-anywhere.md`).

Fail: stop. Watch the Framework BIOS page and the community thread above, and
rerun this procedure after a BIOS update.

**Outcome (2026-10-04): pass.** Three cycles on 6.18.33, two on AC with the
hub and one on battery without it, all entered S4 ("Preparing to enter system
sleep state S4"), powered off on their own in about five seconds, and came
back ("Waking up from system sleep state S4") with the marker and uptime
intact, the battery and AC devices present, and no ACPI errors of any kind.
The `_WAK.G4` failure from the community report did not reproduce on this
unit. The only restore-time error in all three cycles was the `spd5118`
DDR5 SPD sensor driver returning `-6` on resume, which is cosmetic; worth
checking on the installed kernel later, since a failed resume callback on a
sensor costs nothing but a log line. Not exercised here: resume with the
installed kernel, the `xe` driver under a running desktop, and systemd's own
hibernate path. Those come with the real implementation. The design proceeds.
