#!/usr/bin/env bash
#
# sdr-monitor.sh — Tune the RTL-SDR to one frequency, demodulate, record, analyze.
#
# Two things happen:
#   1. A short power measurement of a narrow window around the target gives a
#      live SNR / occupancy read (via rtl_power + analyze).
#   2. The frequency is demodulated (rtl_fm) to audio, which is recorded to WAV
#      and — unless --no-play — played live through your speakers (sox).
#
# Usage:
#   ./sdr-monitor.sh <FREQ> [mode] [seconds] [gain] [--no-play]
#
#   FREQ      e.g. 96.3M, 162.55M, 462.5625M, 119100000
#   mode      wfm (wide FM, broadcast)   default for 88–108 MHz
#             nfm (narrow FM, 2-way/marine/ham)  default elsewhere
#             am  (airband)              default for 118–137 MHz
#   seconds   capture duration (default 30; use 0 for run-until-Ctrl-C, live only)
#   gain      tuner gain dB or "auto" (default auto)
#   --no-play record only, no live audio
#
# Examples:
#   ./sdr-monitor.sh 96.3M                 # local FM station
#   ./sdr-monitor.sh 162.55M nfm 20        # NOAA weather
#   ./sdr-monitor.sh 119.1M am 60          # tower/approach
#   ./sdr-monitor.sh 462.5625M nfm 0       # FRS ch1, listen live until Ctrl-C
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$HERE/recordings"
mkdir -p "$OUTDIR"

[[ $# -lt 1 ]] && { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ---- parse args --------------------------------------------------------------
FREQ_RAW="$1"; shift
MODE=""; SECONDS_ARG=30; GAIN="auto"; PLAY=1
POS=()
for a in "$@"; do
  case "$a" in
    --no-play) PLAY=0 ;;
    *) POS+=("$a") ;;
  esac
done
[[ ${#POS[@]} -ge 1 ]] && MODE="${POS[0]}"
[[ ${#POS[@]} -ge 2 ]] && SECONDS_ARG="${POS[1]}"
[[ ${#POS[@]} -ge 3 ]] && GAIN="${POS[2]}"

# ---- normalize frequency to Hz -----------------------------------------------
to_hz() {
  local f="$1"
  case "$f" in
    *M|*m) echo "$(awk -v x="${f%[Mm]}" 'BEGIN{printf "%.0f", x*1e6}')" ;;
    *k|*K) echo "$(awk -v x="${f%[kK]}" 'BEGIN{printf "%.0f", x*1e3}')" ;;
    *)     echo "$f" ;;
  esac
}
FHZ="$(to_hz "$FREQ_RAW")"
FMHZ="$(awk -v x="$FHZ" 'BEGIN{printf "%.4f", x/1e6}')"

# ---- pick a default mode from the band if not given --------------------------
if [[ -z "$MODE" ]]; then
  if   awk -v f="$FMHZ" 'BEGIN{exit !(f>=88 && f<=108)}'; then MODE="wfm"
  elif awk -v f="$FMHZ" 'BEGIN{exit !(f>=118 && f<=137)}'; then MODE="am"
  else MODE="nfm"; fi
fi

# ---- demod parameters per mode -----------------------------------------------
# rtl_fm: -M modulation, -s sample rate, -r resample (audio out rate)
case "$MODE" in
  wfm) MOD="wbfm"; SAMP=200000;  ARATE=48000; DESC="Wide FM (broadcast)";;
  nfm) MOD="fm";   SAMP=12000;   ARATE=24000; DESC="Narrow FM (2-way / weather / ham)";;
  am)  MOD="am";   SAMP=12000;   ARATE=24000; DESC="AM (airband)";;
  *) echo "error: mode must be wfm | nfm | am (got '$MODE')" >&2; exit 1;;
esac

GAIN_ARG=(); [[ "$GAIN" != "auto" ]] && GAIN_ARG=(-g "$GAIN")
STAMP="$(date +%Y%m%d-%H%M%S)"
WAV="$OUTDIR/${FMHZ}MHz-${MODE}-${STAMP}.wav"

echo "==============================================================="
echo " Frequency : ${FMHZ} MHz   (${FHZ} Hz)"
echo " Mode      : ${MODE}  — ${DESC}"
echo " Gain      : ${GAIN}"
echo " Duration  : $([[ $SECONDS_ARG -eq 0 ]] && echo 'until Ctrl-C (live)' || echo "${SECONDS_ARG}s")"
echo "==============================================================="

# ---- step 1: quick spectral health check around the target ------------------
# Skip for run-forever mode (we go straight to live audio).
if [[ "$SECONDS_ARG" -ne 0 ]]; then
  WIN_LO=$(awk -v f="$FHZ" 'BEGIN{printf "%.0f", f-100000}')
  WIN_HI=$(awk -v f="$FHZ" 'BEGIN{printf "%.0f", f+100000}')
  PWRCSV="$(mktemp -t sdrpwr).csv"
  echo "--> Measuring SNR over ${WIN_LO}-${WIN_HI} Hz (5s) ..."
  if rtl_power -f "${WIN_LO}:${WIN_HI}:2k" -i 1 -e 5 ${GAIN_ARG[@]+"${GAIN_ARG[@]}"} "$PWRCSV" 2>/dev/null; then
    python3 "$HERE/analyze_scan.py" "$PWRCSV" "${PWRCSV%.csv}-inv.csv" 3 2>/dev/null \
      | sed -n '/^Scan:/,$p' || true
  fi
  rm -f "$PWRCSV" "${PWRCSV%.csv}-inv.csv" 2>/dev/null || true
fi

# ---- step 2: demodulate -> record (+ optional live play) ---------------------
echo
echo "--> Demodulating to: $WAV"
[[ $PLAY -eq 1 ]] && echo "    (live audio on — speakers)" || echo "    (recording only)"

# Build the rtl_fm command.
RTLFM=(rtl_fm -f "$FHZ" -M "$MOD" -s "$SAMP" -r "$ARATE" ${GAIN_ARG[@]+"${GAIN_ARG[@]}"} -)

cleanup() { kill ${PIDS[@]+"${PIDS[@]}"} 2>/dev/null || true; }
trap cleanup INT TERM
PIDS=()

# rtl_fm emits raw signed 16-bit mono PCM at $ARATE.
RAWFMT=(-t raw -r "$ARATE" -e signed-integer -b 16 -c 1 -)

if [[ "$SECONDS_ARG" -eq 0 ]]; then
  # Live forever: rtl_fm -> sox play (no fixed length). Recording skipped here.
  if [[ $PLAY -eq 1 ]]; then
    "${RTLFM[@]}" 2>/dev/null | sox "${RAWFMT[@]}" -d
  else
    echo "    (nothing to do: --no-play with 0s). Use a duration to record." >&2
  fi
else
  # Fixed duration: sox's `trim 0 N` bounds the capture, then exits — closing
  # the pipe and stopping rtl_fm via SIGPIPE (macOS has no `timeout`).
  if [[ $PLAY -eq 1 ]]; then
    # Record to WAV, and fan a live copy to the speakers via process subst.
    "${RTLFM[@]}" 2>/dev/null \
      | tee >(sox "${RAWFMT[@]}" -d trim 0 "$SECONDS_ARG" 2>/dev/null) \
      | sox "${RAWFMT[@]}" "$WAV" trim 0 "$SECONDS_ARG" 2>/dev/null || true
  else
    "${RTLFM[@]}" 2>/dev/null \
      | sox "${RAWFMT[@]}" "$WAV" trim 0 "$SECONDS_ARG" 2>/dev/null || true
  fi
fi

trap - INT TERM

# ---- step 3: post-capture audio analysis ------------------------------------
if [[ -f "$WAV" ]]; then
  echo
  echo "--> Recording saved: $WAV"
  echo "    Audio stats:"
  sox "$WAV" -n stat 2>&1 | sed 's/^/      /' || true
  DUR=$(sox "$WAV" -n stat 2>&1 | awk -F: '/Length/{print $2}')
  echo
  echo "    Play it back:   play \"$WAV\""
  echo "    Spectrogram:    sox \"$WAV\" -n spectrogram -o \"${WAV%.wav}.png\""
fi
