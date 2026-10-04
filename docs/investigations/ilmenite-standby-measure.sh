#!/usr/bin/env bash
# Standby power measurement for the ilmenite standby spike.
# Usage: ./ilmenite-standby-measure.sh before|after <label>
# Run as the normal user; sudo is used only for the root-only debugfs reads.
# Writes $HOME/standby-<label>-<phase>.txt.
set -u
phase=$1
label=$2
out=$HOME/standby-$label-$phase.txt
{
  echo "time $(date +%s)"
  echo "ac_online $(cat /sys/class/power_supply/ACAD/online)"
  echo "charge_now $(cat /sys/class/power_supply/BAT1/charge_now)"
  echo "voltage_now $(cat /sys/class/power_supply/BAT1/voltage_now)"
  echo "slp_s0_residency_usec $(sudo cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec)"
  echo "--- substate_residencies ---"
  sudo cat /sys/kernel/debug/pmc_core/substate_residencies
  if [ "$phase" = after ]; then
    echo "--- suspend entry/exit ---"
    journalctl -b -k --no-pager | grep -E "PM: suspend (entry|exit)" | tail -n 2
    echo "--- s0ix_blocker ---"
    sudo cat /sys/kernel/debug/pmc_core/s0ix_blocker 2>/dev/null || echo "(not readable)"
    echo "--- BERT count ---"
    journalctl -b -k --no-pager | grep -ic BERT
    echo "--- boots ---"
    journalctl --list-boots --no-pager | tail -n 2
  fi
} >"$out"
echo "wrote $out"
