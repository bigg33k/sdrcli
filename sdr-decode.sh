#!/usr/bin/env bash
#
# sdr-decode.sh — Decode digital modes from an RTL-SDR frequency with multimon-ng.
#
# Tunes rtl_fm to the target (narrow FM, 22.05 kHz audio — what multimon-ng wants),
# pipes the audio into multimon-ng with the right demodulator(s), and logs every
# decoded line to decodes/ with timestamps.
#
# Usage:
#   ./sdr-decode.sh <FREQ> <protocol> [seconds] [gain]
#
#   FREQ       e.g. 929.8625M, 144.39M, 462.5625M, 148556200
#   protocol   pager   POCSAG (512/1200/2400) + FLEX  -- on-screen text pagers
#              pocsag  POCSAG only
#              flex    FLEX only
#              aprs    AFSK1200 / AX.25 packet (TNC2 output)
#              dtmf    touch-tones
#              zvei    ZVEI/EEA/EIA selective-call tones
#              morse   CW (Morse)
#              all     pager + aprs + dtmf + zvei (kitchen sink)
#   seconds    capture duration (default 60; 0 = run until Ctrl-C)
#   gain       tuner gain dB or "auto" (default auto)
#
# Examples:
#   ./sdr-decode.sh 929.8625M pager 120        # listen to a pager channel 2 min
#   ./sdr-decode.sh 144.39M  aprs  0           # APRS (US), live until Ctrl-C
#   ./sdr-decode.sh 462.5625M dtmf 30          # FRS ch1, catch any DTMF
#
# Find candidate channels first with: ./sdr-scan.sh pager   (or  wide-uhf, etc.)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MM="$HERE/vendor/multimon-ng/build/multimon-ng"
OUTDIR="$HERE/decodes"
mkdir -p "$OUTDIR"

[[ ! -x "$MM" ]] && { echo "error: multimon-ng not built at $MM" >&2; echo "build it: (cd vendor/multimon-ng && mkdir -p build && cd build && cmake .. && make)" >&2; exit 1; }
[[ $# -lt 2 ]] && { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

FREQ_RAW="$1"; PROTO="$2"; SECONDS_ARG="${3:-60}"; GAIN="${4:-auto}"

# ---- normalize frequency to Hz -----------------------------------------------
to_hz() {
  local f="$1"
  case "$f" in
    *M|*m) awk -v x="${f%[Mm]}" 'BEGIN{printf "%.0f", x*1e6}' ;;
    *k|*K) awk -v x="${f%[kK]}" 'BEGIN{printf "%.0f", x*1e3}' ;;
    *)     echo "$f" ;;
  esac
}
FHZ="$(to_hz "$FREQ_RAW")"
FMHZ="$(awk -v x="$FHZ" 'BEGIN{printf "%.4f", x/1e6}')"

# ---- map protocol -> multimon-ng demodulator flags ---------------------------
DEMODS=(); EXTRA=()
case "$PROTO" in
  pager)  DEMODS=(-a POCSAG512 -a POCSAG1200 -a POCSAG2400 -a FLEX -a FLEX_NEXT); EXTRA=(-e -u) ;;
  pocsag) DEMODS=(-a POCSAG512 -a POCSAG1200 -a POCSAG2400); EXTRA=(-e -u) ;;
  flex)   DEMODS=(-a FLEX -a FLEX_NEXT) ;;
  aprs)   DEMODS=(-a AFSK1200); EXTRA=(-A) ;;
  dtmf)   DEMODS=(-a DTMF) ;;
  zvei)   DEMODS=(-a ZVEI1 -a ZVEI2 -a EEA -a EIA -a CCIR) ;;
  morse)  DEMODS=(-a MORSE_CW) ;;
  all)    DEMODS=(-a POCSAG512 -a POCSAG1200 -a POCSAG2400 -a FLEX -a FLEX_NEXT \
                  -a AFSK1200 -a DTMF -a ZVEI1 -a ZVEI2); EXTRA=(-e -u -A) ;;
  *) echo "error: unknown protocol '$PROTO' (pager|pocsag|flex|aprs|dtmf|zvei|morse|all)" >&2; exit 1 ;;
esac

GAIN_ARG=(); [[ "$GAIN" != "auto" ]] && GAIN_ARG=(-g "$GAIN")
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUTDIR/${FMHZ}MHz-${PROTO}-${STAMP}.log"

echo "==============================================================="
echo " Frequency : ${FMHZ} MHz   (${FHZ} Hz)"
echo " Protocol  : ${PROTO}   [${DEMODS[*]}]"
echo " Gain      : ${GAIN}"
echo " Duration  : $([[ "$SECONDS_ARG" -eq 0 ]] && echo 'until Ctrl-C' || echo "${SECONDS_ARG}s")"
echo " Log       : ${LOG}"
echo "==============================================================="
echo " Decoded traffic (also appended to log):"
echo "---------------------------------------------------------------"

# rtl_fm narrow-FM at 22.05 kHz mono == multimon-ng's native raw format.
RTLFM=(rtl_fm -f "$FHZ" -M fm -s 22050 ${GAIN_ARG[@]+"${GAIN_ARG[@]}"} -)
RAWFMT=(-t raw -r 22050 -e signed-integer -b 16 -c 1 -)
MMCMD=("$MM" -t raw "${DEMODS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} --timestamp -)

# Header into the log too.
{ echo "# ${FMHZ} MHz  proto=${PROTO}  gain=${GAIN}  started=${STAMP}"; } >> "$LOG"

if [[ "$SECONDS_ARG" -eq 0 ]]; then
  # Run until Ctrl-C.
  "${RTLFM[@]}" 2>/dev/null | "${MMCMD[@]}" 2>/dev/null | tee -a "$LOG"
else
  # Bound the run with sox `trim` (macOS has no `timeout`); sox exiting
  # closes the pipe and stops rtl_fm via SIGPIPE.
  "${RTLFM[@]}" 2>/dev/null \
    | sox "${RAWFMT[@]}" "${RAWFMT[@]}" trim 0 "$SECONDS_ARG" 2>/dev/null \
    | "${MMCMD[@]}" 2>/dev/null | tee -a "$LOG" || true
fi

echo "---------------------------------------------------------------"
# Count real decodes: exclude our header, blank lines, and multimon-ng's banner.
HITS=$(grep -vE '^#|^$|^Enabled demodulators' "$LOG" 2>/dev/null | grep -c . || true)
echo "==> Done. ${HITS:-0} decoded message(s) in: $LOG"
[[ "${HITS:-0}" -eq 0 ]] && echo "    (no traffic decoded — try a known-active channel, longer run, or set gain)"
