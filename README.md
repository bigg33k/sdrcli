# RTL-SDR Scan / Inventory / Monitor Toolkit

A small, dependency-light workflow for an **RTL2832U / R820T** USB software-defined
radio on macOS (Apple Silicon). Detect → scan a band → inventory the active
signals → pick one frequency → monitor and analyze it.

## Hardware detected

| Field        | Value                          |
|--------------|--------------------------------|
| Device       | `RTL2838UHIDIR` (Realtek)      |
| Tuner        | Rafael Micro **R820T**         |
| USB ID       | `0x0BDA:0x2838`                |
| Serial       | `00001581`                     |
| Tunable      | ~24 MHz – 1.7 GHz              |
| Sample rate  | up to ~2.4 MS/s                |

## Toolchain

- `rtl-sdr` — `rtl_test`, `rtl_power` (sweep), `rtl_fm` (demod), `rtl_sdr` (raw IQ)
- `sox` — audio record / playback / stats / spectrogram
- Python 3 (stdlib only) — `analyze_scan.py` peak detection
- `multimon-ng` — digital-mode decoder (POCSAG/FLEX pagers, APRS, DTMF, ZVEI, CW),
  built from source into `vendor/multimon-ng/build/`

```sh
brew install rtl-sdr sox cmake pkg-config
# multimon-ng (not in brew core) — built from source:
git clone --depth 1 https://github.com/EliasOenal/multimon-ng vendor/multimon-ng
(cd vendor/multimon-ng && mkdir -p build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make)
```

## Quick start — interactive (recommended)

One script does scan + listen with an **arrow-key menu**:

```sh
./sdr.sh
```
Navigate with **↑/↓** (or j/k), **Enter** to select, **q** to cancel/back.
Pick a band → it scans → arrow-select a detected signal → Enter to **listen
live** through your speakers (it also prompts for the demod mode, preselecting
the auto-detected one). Ctrl-C stops listening and returns to the menu.
The signal list also has action rows: ↻ rescan, ← back to bands, ⚙ set gain,
✕ quit.

- **Remembers scans per band.** Results are cached under `scans/`, so the next
  launch jumps straight to your last signal list, and picking any band you've
  scanned before loads instantly instead of re-scanning. Empty/failed scans are
  skipped, so you always get the last *good* result. Pick *↻ Rescan* for fresh
  data whenever you want it.
- **Scrolls long lists.** When a band has more signals than fit on screen, the
  menu shows a sliding viewport with a `[x-y of N]` position counter and
  `▲more`/`▼more` indicators. Override the assumed height with `SDR_ROWS=N` if
  `tput` can't read your terminal size.

Tunables via env: `GAIN`, `BIN`, `DWELL` (e.g. `GAIN=40 DWELL=30 ./sdr.sh`).
Needs an interactive terminal (arrow keys); runs on the stock macOS bash 3.2.

The individual scripts below are still available for scripting / one-shot use.

## Workflow

### 1. Verify the dongle
```sh
rtl_test            # Ctrl-C to stop; confirms device + tuner + gains
```

### 2. Scan a band and inventory signals
```sh
./sdr-scan.sh <preset|LOW:HIGH> [bin_hz] [dwell_sec] [gain]
```
Sweeps the range with `rtl_power`, time-averages each FFT bin, estimates the
noise floor, groups bins that rise above it into discrete signals, and labels
each with a likely service. Outputs go to `scans/`:
- `scan-*.csv` — raw power spectrum
- `inventory-*.csv` — detected signals: freq, peak dB, SNR, bandwidth, service

Presets: `fm airband noaa marine 2m 70cm pmr-frs pager ads-b wide-vhf wide-uhf`
(run `./sdr-scan.sh` with no args to list them with ranges).

```sh
./sdr-scan.sh fm                 # FM broadcast, default bin/dwell
./sdr-scan.sh airband 4k 30      # finer bins, 30s dwell
./sdr-scan.sh 462M:468M 5k 25 28 # custom range, gain 28 dB
```

### 3. Monitor + analyze one frequency
```sh
./sdr-monitor.sh <FREQ> [mode] [seconds] [gain] [--no-play]
```
1. Measures SNR/occupancy in a ±100 kHz window around the target.
2. Demodulates with `rtl_fm` → records WAV in `recordings/` (and plays live
   unless `--no-play`).
3. Prints `sox` audio stats; suggests playback + spectrogram commands.

Modes: `wfm` (broadcast FM), `nfm` (narrow FM: 2-way/marine/weather/ham),
`am` (airband). Auto-picked from the band if omitted.
Use `seconds = 0` to listen live until Ctrl-C.

```sh
./sdr-monitor.sh 90.1M               # broadcast FM, 30s, live audio
./sdr-monitor.sh 162.55M nfm 20      # NOAA weather, 20s
./sdr-monitor.sh 119.1M am 60        # airband, 60s
./sdr-monitor.sh 462.5625M nfm 0     # FRS ch1, listen until Ctrl-C
```

### 4. Decode digital modes
```sh
./sdr-decode.sh <FREQ> <protocol> [seconds] [gain]
```
Tunes narrow-FM at 22.05 kHz (multimon-ng's native rate) and decodes:

| protocol | modes                                   | typical where            |
|----------|-----------------------------------------|--------------------------|
| `pager`  | POCSAG 512/1200/2400 + FLEX             | 929–932, 152–159 MHz (US)|
| `pocsag` | POCSAG only                             | "                        |
| `flex`   | FLEX only                               | "                        |
| `aprs`   | AFSK1200 / AX.25 packet (TNC2 output)   | 144.39 MHz (US)          |
| `dtmf`   | touch-tones                             | any voice channel        |
| `zvei`   | ZVEI/EEA/EIA/CCIR selective-call tones  | land-mobile paging       |
| `morse`  | CW                                      | ham CW segments          |
| `all`    | pager + aprs + dtmf + zvei              | scattershot              |

Every decoded line is timestamped and appended to `decodes/`.
```sh
./sdr-decode.sh 929.8625M pager 120     # pager channel, 2 minutes
./sdr-decode.sh 144.39M  aprs  0        # APRS, live until Ctrl-C
./sdr-decode.sh 462.5625M dtmf 30       # FRS ch1, any touch-tones
```

### 5. Inspect a recording
```sh
play recordings/<file>.wav
sox  recordings/<file>.wav -n spectrogram -o out.png
```

## Files
```
sdr.sh             interactive scan + listen menu (main entry point)
sdr-scan.sh        band sweep -> signal inventory
analyze_scan.py    rtl_power CSV -> peak detection + service labels (stdlib)
sdr-monitor.sh     tune one freq -> SNR check + demod + record + stats
sdr-decode.sh      tune one freq -> multimon-ng digital decode -> timestamped log
vendor/multimon-ng built-from-source decoder
scans/             raw spectra + inventories  (created on first scan)
recordings/        WAV captures + spectrograms (created on first monitor)
decodes/           timestamped decode logs    (created on first decode)
```

## Notes & tips
- Antenna matters most. The bundled whip is fine for FM/airband; higher bands
  want a proper antenna.
- If a scan finds nothing: increase `dwell_sec`, set an explicit `gain`
  (e.g. `40`), or confirm the band is actually active in your area.
- **Antenna sanity check:** NOAA weather radio (162.400–162.550 MHz) is
  always transmitting in the US. If `./sdr-scan.sh noaa 2k 15 40` finds nothing,
  your antenna isn't receiving VHF — extend the telescoping whip to ~46 cm and
  move near a window/outdoors before chasing weak signals like pager/APRS.
- **DC-spike artifacts:** the RTL2832U zero-IF tuner emits a spurious spike at
  each tuning center. `rtl_power` reports these as narrow "signals" that
  demodulate to pure noise. A scan hit is suspect if it's a single ~1-bin spike
  that produces only noise when you `./sdr-monitor.sh` it. Real transmitters
  have realistic bandwidth and audible/decodable content.
- `gain auto` is the default; manual gain (0–49.6 dB on this R820T) can pull
  weak signals out of the noise or reduce overload from strong ones.
- The R820T cannot tune below ~24 MHz, so HF/shortwave needs an upconverter.
- Legal: receive-only. Listening to some services may be restricted in your
  jurisdiction — know your local rules.
```
