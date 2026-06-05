#!/usr/bin/env bash
#
# sdr.sh — Interactive scan + listen front-end for the RTL-SDR.
#
# Navigation is arrow-key driven:  ↑/↓ (or j/k) move, Enter selects, q cancels.
#
# Flow:  pick a band  ->  it scans  ->  arrow-select a found signal  ->
#        Enter to listen live  ->  Ctrl-C returns to the menu.
#
# Reuses analyze_scan.py for peak detection and the same rtl_power / rtl_fm / sox
# chain as the standalone scripts. Scan CSVs are saved under scans/.
#
# Tunables (env, or the "Set gain" menu item):
#   GAIN  tuner gain dB or "auto"  (default auto)
#   BIN   FFT bin width for scans  (default 8k)
#   DWELL scan duration seconds    (default 20)
#
set -o pipefail   # no -e/-u: keep the interactive loop resilient

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANDIR="$HERE/scans"
ANALYZER="$HERE/analyze_scan.py"
mkdir -p "$SCANDIR"

GAIN="${GAIN:-auto}"
BIN="${BIN:-8k}"
DWELL="${DWELL:-20}"

# Parallel arrays describing the most recent scan's signals.
FREQS=(); SNRS=(); SVCS=(); MODES=()
LAST_RANGE=""; LAST_LABEL=""; LAST_INV=""; LAST_WHEN=""

# Where the last-scan pointer is cached between runs.
STATE="$HERE/.last_scan"

# menu_select results
MENU_CHOICE=-1
MENU_START=0

# Always restore the cursor on exit.
trap 'printf "\033[?25h"' EXIT

# ---- band presets (label|range), in display order ---------------------------
PRESET_LABELS=(fm airband noaa marine 2m 70cm pmr-frs pager wide-vhf wide-uhf)
preset_range() {
  case "$1" in
    fm)       echo "88M:108M"     ;;
    airband)  echo "118M:137M"    ;;
    noaa)     echo "162.3M:162.6M";;
    marine)   echo "156M:162M"    ;;
    2m)       echo "144M:148M"    ;;
    70cm)     echo "420M:450M"    ;;
    pmr-frs)  echo "446M:467M"    ;;
    pager)    echo "929M:932M"    ;;
    wide-vhf) echo "130M:175M"    ;;
    wide-uhf) echo "400M:512M"    ;;
    *)        echo ""             ;;
  esac
}

# ---- arrow-key menu ----------------------------------------------------------
# Usage: menu_select "Header text" "opt0" "opt1" ...
# Sets MENU_CHOICE to the chosen 0-based index; returns 0.
# Returns 1 (MENU_CHOICE=-1) if the user cancels with q/ESC.
# Set MENU_START before calling to preselect an index (reset to 0 after).
menu_select() {
  local header="$1"; shift
  local opts=("$@")
  local n="${#opts[@]}"
  local cur="${MENU_START:-0}"
  MENU_START=0
  [ "$cur" -ge "$n" ] && cur=0
  local first=1 i idx key rest

  # Size the viewport to the terminal: leave room for header, hint, and the
  # scan output printed above. Scroll within `vis` rows when the list is taller.
  local rows vis top
  rows="${SDR_ROWS:-$(tput lines 2>/dev/null)}"; [ -z "$rows" ] && rows=24
  vis=$(( rows - 6 )); [ "$vis" -lt 4 ] && vis=4
  [ "$vis" -gt "$n" ] && vis="$n"
  top=0
  [ "$cur" -ge $(( top + vis )) ] && top=$(( cur - vis + 1 ))

  printf '\033[?25l'   # hide cursor
  while true; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf '\033[%dA' $(( vis + 2 ))   # back up over header + viewport + hint
    fi
    printf '\r\033[K\033[1m%s\033[0m\n' "$header"
    for i in $(seq 0 $(( vis - 1 )) ); do
      idx=$(( top + i ))
      if [ "$idx" -eq "$cur" ]; then
        printf '\r\033[K\033[7m  ▶ %s \033[0m\n' "${opts[$idx]}"
      else
        printf '\r\033[K    %s\n' "${opts[$idx]}"
      fi
    done
    # Hint line shows position + which directions have more off-screen.
    local more=""
    [ "$top" -gt 0 ] && more="${more} ▲more"
    [ $(( top + vis )) -lt "$n" ] && more="${more} ▼more"
    printf '\r\033[K  \033[2m↑/↓ move · Enter select · q cancel   [%d-%d of %d]%s\033[0m\n' \
      $(( top + 1 )) $(( top + vis )) "$n" "$more"

    IFS= read -rsn1 key || { printf '\033[?25h'; MENU_CHOICE=-1; return 1; }
    if [ "$key" = $'\033' ]; then
      # Grab the escape tail. Integer timeout only — bash 3.2 has no fractional -t.
      # Arrow keys deliver "[A"/"[B" instantly, so this returns without waiting.
      IFS= read -rsn2 -t 1 rest 2>/dev/null
      key+="$rest"
    fi
    case "$key" in
      $'\033[A'|$'\033OA'|k|K) cur=$(( (cur - 1 + n) % n )) ;;
      $'\033[B'|$'\033OB'|j|J) cur=$(( (cur + 1) % n )) ;;
      ''|$'\n'|$'\r')          printf '\033[?25h'; MENU_CHOICE="$cur"; return 0 ;;
      q|Q|$'\033')             printf '\033[?25h'; MENU_CHOICE=-1; return 1 ;;
    esac
    # Keep the highlighted row inside the viewport (handles wrap-around too).
    [ "$cur" -lt "$top" ] && top="$cur"
    [ "$cur" -ge $(( top + vis )) ] && top=$(( cur - vis + 1 ))
  done
}

# ---- helpers -----------------------------------------------------------------
mode_for() {  # auto-pick demod mode from a frequency in MHz
  awk -v f="$1" 'BEGIN{
    if (f>=88 && f<=108)       print "wfm";
    else if (f>=118 && f<=137) print "am";
    else                       print "nfm";
  }'
}

to_hz() {
  case "$1" in
    *M|*m) awk -v x="${1%[Mm]}" 'BEGIN{printf "%.0f", x*1e6}' ;;
    *k|*K) awk -v x="${1%[kK]}" 'BEGIN{printf "%.0f", x*1e3}' ;;
    *)     echo "$1" ;;
  esac
}

need_tools() {
  local miss=0
  for t in rtl_power rtl_fm sox python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; miss=1; }
  done
  [ -f "$ANALYZER" ] || { echo "missing $ANALYZER" >&2; miss=1; }
  [ "$miss" -eq 0 ]
}

# ---- load an inventory CSV into the parallel arrays --------------------------
load_inventory() {
  local inv="$1"
  FREQS=(); SNRS=(); SVCS=(); MODES=()
  local fmhz peak snr bw svc
  while IFS=, read -r fmhz peak snr bw svc; do
    [ -z "$fmhz" ] && continue
    FREQS+=("$fmhz"); SNRS+=("$snr"); SVCS+=("$svc")
    MODES+=("$(mode_for "$fmhz")")
  done < <(tail -n +2 "$inv")
}

# ---- persist / restore the last scan so we can skip the scan delay -----------
save_state() {
  printf '%s\n%s\n%s\n%s\n' "$LAST_LABEL" "$LAST_RANGE" "$LAST_INV" \
    "$(date '+%Y-%m-%d %H:%M')" > "$STATE" 2>/dev/null
}

# Returns 0 and fills the arrays if a usable cached scan exists.
load_state() {
  [ -f "$STATE" ] || return 1
  local label range inv when
  { IFS= read -r label; IFS= read -r range; IFS= read -r inv; IFS= read -r when; } < "$STATE"
  [ -n "$inv" ] && [ -f "$inv" ] || return 1
  LAST_LABEL="$label"; LAST_RANGE="$range"; LAST_INV="$inv"; LAST_WHEN="$when"
  load_inventory "$inv"
  [ "${#FREQS[@]}" -gt 0 ] || return 1   # don't auto-load an empty result
  return 0
}

# ---- reuse the newest cached inventory for a band, else scan -----------------
# This is what the band menu calls: picking a band you've scanned before loads
# instantly; use the ↻ Rescan action in the signal menu to refresh.
load_or_scan() {
  local range="$1" label="$2"
  # Pick the newest inventory for this band that actually has signals — skip
  # empty results from failed/quiet scans so we don't cache "0 signals".
  local inv="" f
  for f in $(ls -t "$SCANDIR"/inventory-"${label}"-*.csv 2>/dev/null); do
    if [ "$(tail -n +2 "$f" 2>/dev/null | grep -c .)" -gt 0 ]; then inv="$f"; break; fi
  done
  if [ -n "$inv" ] && [ -f "$inv" ]; then
    LAST_RANGE="$range"; LAST_LABEL="$label"; LAST_INV="$inv"
    LAST_WHEN="$(date -r "$inv" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    load_inventory "$inv"
    save_state
    echo
    echo "↺ Loaded cached '${label}' — ${#FREQS[@]} signal(s) from ${LAST_WHEN}."
    echo "  (pick ↻ Rescan in the menu to refresh)"
  else
    scan_band "$range" "$label"
  fi
}

# ---- scan a range, load results, and cache them ------------------------------
scan_band() {
  local range="$1" label="$2"
  LAST_RANGE="$range"; LAST_LABEL="$label"
  local stamp raw inv
  stamp="$(date +%Y%m%d-%H%M%S)"
  raw="$SCANDIR/scan-${label}-${stamp}.csv"
  inv="$SCANDIR/inventory-${label}-${stamp}.csv"
  local gain_arg=(); [ "$GAIN" != "auto" ] && gain_arg=(-g "$GAIN")

  echo
  echo ">> Scanning '${label}'  range=${range}  bin=${BIN}  dwell=${DWELL}s  gain=${GAIN}  (~${DWELL}s)"
  if ! rtl_power -f "${range}:${BIN}" -i 1 -e "$DWELL" ${gain_arg[@]+"${gain_arg[@]}"} "$raw" 2>/dev/null; then
    echo "!! rtl_power failed — is the dongle plugged in and free?"
    return 1
  fi
  python3 "$ANALYZER" "$raw" "$inv" >/dev/null 2>&1
  LAST_INV="$inv"
  load_inventory "$inv"
  save_state
  echo "   found ${#FREQS[@]} signal(s)."
}

# ---- listen live to one frequency (Ctrl-C returns to menu) -------------------
listen() {
  local fmhz="$1" mode="$2"
  local fhz mod samp arate
  fhz="$(to_hz "${fmhz}M")"
  case "$mode" in
    wfm) mod=wbfm; samp=200000; arate=48000 ;;
    nfm) mod=fm;   samp=12000;  arate=24000 ;;
    am)  mod=am;   samp=12000;  arate=24000 ;;
    *)   echo "unknown mode '$mode'"; return 1 ;;
  esac
  local gain_arg=(); [ "$GAIN" != "auto" ] && gain_arg=(-g "$GAIN")

  echo
  echo "  ▶ Listening: ${fmhz} MHz  [${mode}]  gain=${GAIN}"
  echo "    Press Ctrl-C to stop and return to the menu."
  echo
  trap ':' INT   # absorb Ctrl-C here so it stops playback, not the script
  rtl_fm -f "$fhz" -M "$mod" -s "$samp" -r "$arate" ${gain_arg[@]+"${gain_arg[@]}"} - 2>/dev/null \
    | sox -t raw -r "$arate" -e signed-integer -b 16 -c 1 - -d 2>/dev/null
  trap - INT
  echo
  echo "  ⏹ Stopped."
}

# ---- demod-mode picker (preselects the auto-detected mode) -------------------
MODE_SEL=""
choose_mode() {
  local def="$1"
  case "$def" in wfm) MENU_START=0 ;; nfm) MENU_START=1 ;; am) MENU_START=2 ;; esac
  if menu_select "Demod mode:" \
       "wfm  — wide FM (broadcast)" \
       "nfm  — narrow FM (2-way / weather / ham)" \
       "am   — airband"; then
    case "$MENU_CHOICE" in 0) MODE_SEL=wfm ;; 1) MODE_SEL=nfm ;; 2) MODE_SEL=am ;; esac
  else
    MODE_SEL="$def"   # cancelled -> keep auto mode
  fi
}

set_gain() {
  printf '\033[?25h'
  local ng
  read -rp "  Gain dB (0-49.6) or 'auto': " ng
  [ -n "$ng" ] && GAIN="$ng" && echo "  gain set to ${GAIN}"
}

# ---- band-selection menu -----------------------------------------------------
# returns 9 to quit the program, 0 after a scan, 1 to redraw.
choose_band() {
  local opts=() i lbl
  for i in $(seq 0 $(( ${#PRESET_LABELS[@]} - 1 )) ); do
    lbl="${PRESET_LABELS[$i]}"
    opts+=("$(printf '%-9s %s' "$lbl" "$(preset_range "$lbl")")")
  done
  opts+=("Custom range…")
  opts+=("Quit")

  menu_select "Choose a band to scan:" "${opts[@]}" || return 9
  local c="$MENU_CHOICE"
  local nP="${#PRESET_LABELS[@]}"
  if [ "$c" -lt "$nP" ]; then
    lbl="${PRESET_LABELS[$c]}"
    load_or_scan "$(preset_range "$lbl")" "$lbl"
  elif [ "$c" -eq "$nP" ]; then
    printf '\033[?25h'
    local r
    read -rp "  Enter range LOW:HIGH (Hz or M/k suffix, e.g. 462M:468M): " r
    [ -n "$r" ] && scan_band "$r" "custom" || return 1
  else
    return 9   # Quit
  fi
}

# ---- listen menu (after a scan) ----------------------------------------------
# returns 9 to quit, 0 to go back to band menu.
listen_menu() {
  while true; do
    local opts=() i header
    local base="${#FREQS[@]}"
    if [ "$base" -eq 0 ]; then
      header="No signals found in '${LAST_LABEL}'."
    else
      header="Signals in '${LAST_LABEL}' — select one to listen:"
      for i in $(seq 0 $(( base - 1 )) ); do
        opts+=("$(printf '%-11s  SNR %5s+  %-3s  %s' \
                  "${FREQS[$i]}" "${SNRS[$i]}" "${MODES[$i]}" "${SVCS[$i]}")")
      done
    fi
    opts+=("↻  Rescan this band")
    opts+=("←  Back to band menu")
    opts+=("⚙  Set gain (now: ${GAIN})")
    opts+=("✕  Quit")

    menu_select "$header" "${opts[@]}" || return 9
    local c="$MENU_CHOICE"
    if [ "$base" -gt 0 ] && [ "$c" -lt "$base" ]; then
      choose_mode "${MODES[$c]}"
      listen "${FREQS[$c]}" "$MODE_SEL"
    else
      case $(( c - base )) in
        0) scan_band "$LAST_RANGE" "$LAST_LABEL" ;;
        1) return 0 ;;        # back to bands
        2) set_gain ;;
        3) return 9 ;;        # quit
      esac
    fi
  done
}

# ---- main --------------------------------------------------------------------
main() {
  need_tools || { echo "Fix the missing tools above and retry."; exit 1; }
  if [ ! -t 0 ]; then
    echo "Note: stdin is not a terminal — arrow-key navigation needs an interactive shell." >&2
  fi
  echo "RTL-SDR scan + listen   (gain=${GAIN}, bin=${BIN}, dwell=${DWELL}s)"

  # If we have a cached scan, jump straight to its signal list (no scan delay).
  if load_state; then
    echo "↺ Loaded last scan: '${LAST_LABEL}' — ${#FREQS[@]} signal(s) from ${LAST_WHEN}."
    echo "  (pick ↻ Rescan in the menu to refresh)"
    listen_menu; rc=$?
    [ "$rc" -eq 9 ] && { printf '\033[?25h'; echo "73s. (bye)"; return; }
  fi

  while true; do
    choose_band; rc=$?
    [ "$rc" -eq 9 ] && break       # quit from band menu
    [ "$rc" -ne 0 ] && continue    # bad/cancelled -> redraw band menu
    listen_menu; rc=$?
    [ "$rc" -eq 9 ] && break       # quit from listen menu
  done
  printf '\033[?25h'
  echo "73s. (bye)"
}

main "$@"
