#!/usr/bin/env bash
#
# sdr-scan.sh — Sweep a frequency band with an RTL-SDR and inventory active signals.
#
# Uses rtl_power to measure power across a range, then analyze_scan.py to find
# peaks above the noise floor and label them with likely service allocations.
#
# Usage:
#   ./sdr-scan.sh <preset|LOW:HIGH> [bin_hz] [dwell_sec] [gain]
#
#   preset       one of the named bands below (run with no args to list)
#   LOW:HIGH     custom range in Hz or with M/k suffix, e.g. 144M:148M
#   bin_hz       FFT bin width (default 8k)  -- smaller = finer, slower
#   dwell_sec    total scan duration (default 20)
#   gain         tuner gain in dB or "auto" (default auto)
#
# Examples:
#   ./sdr-scan.sh fm
#   ./sdr-scan.sh airband 4k 30
#   ./sdr-scan.sh 400M:470M 12k 25 28
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$HERE/scans"
mkdir -p "$OUTDIR"

# ---- band presets (RTL-SDR / R820T usable range ~24 MHz – 1.7 GHz) -----------
# Portable lookup (macOS bash 3.2 has no associative arrays): preset -> range.
preset_range() {
  case "$1" in
    fm)       echo "88M:108M"     ;;  # FM broadcast
    airband)  echo "118M:137M"    ;;  # VHF civil aviation (AM)
    noaa)     echo "162.3M:162.6M";;  # NOAA weather radio
    marine)   echo "156M:162M"    ;;  # VHF marine
    2m)       echo "144M:148M"    ;;  # 2 m amateur
    70cm)     echo "420M:450M"    ;;  # 70 cm amateur
    pmr-frs)  echo "446M:467M"    ;;  # FRS/GMRS/PMR handhelds
    pager)    echo "148M:160M"    ;;  # POCSAG/FLEX paging
    ads-b)    echo "1090M:1090.1M";;  # aircraft transponders (narrow)
    wide-vhf) echo "130M:175M"    ;;  # general VHF land-mobile sweep
    wide-uhf) echo "400M:512M"    ;;  # general UHF land-mobile sweep
    *)        echo ""             ;;
  esac
}

usage() {
  echo "Usage: $(basename "$0") <preset|LOW:HIGH> [bin_hz] [dwell_sec] [gain]"
  echo
  echo "Presets:"
  for k in fm airband noaa marine 2m 70cm pmr-frs pager ads-b wide-vhf wide-uhf; do
    printf "  %-10s %s\n" "$k" "$(preset_range "$k")"
  done
  echo
  echo "Custom range example: $(basename "$0") 462M:468M 5k 30 auto"
  exit 1
}

[[ $# -lt 1 ]] && usage

SEL="$1"
BIN="${2:-8k}"
DWELL="${3:-20}"
GAIN="${4:-auto}"

PRANGE="$(preset_range "$SEL")"
if [[ -n "$PRANGE" ]]; then
  RANGE="$PRANGE"
  LABEL="$SEL"
else
  RANGE="$SEL"
  LABEL="custom"
fi

if [[ "$RANGE" != *:* ]]; then
  echo "error: range must be PRESET or LOW:HIGH (got '$RANGE')" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
RAW="$OUTDIR/scan-${LABEL}-${STAMP}.csv"
INV="$OUTDIR/inventory-${LABEL}-${STAMP}.csv"

GAIN_ARG=()
[[ "$GAIN" != "auto" ]] && GAIN_ARG=(-g "$GAIN")

echo "==> Scanning $LABEL  range=$RANGE  bin=$BIN  dwell=${DWELL}s  gain=$GAIN"
echo "    raw power -> $RAW"

# rtl_power: -f range:binwidth  -i integration interval  -e total runtime
rtl_power -f "${RANGE}:${BIN}" -i 1 -e "$DWELL" ${GAIN_ARG[@]+"${GAIN_ARG[@]}"} "$RAW"

echo "==> Analyzing for active signals ..."
python3 "$HERE/analyze_scan.py" "$RAW" "$INV"

echo
echo "==> Inventory written to: $INV"
echo "    Monitor a hit with:   ./sdr-monitor.sh <freq_mhz>M <mode>"
