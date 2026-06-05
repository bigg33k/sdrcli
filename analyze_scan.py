#!/usr/bin/env python3
"""
analyze_scan.py — Turn an rtl_power CSV sweep into a signal inventory.

rtl_power emits rows of:
    date, time, hz_low, hz_high, hz_step, n_samples, db_bin0, db_bin1, ...
A wide sweep is split into several segments per timestamp and repeated over time.

This script:
  1. Averages each frequency bin's power over the whole capture (time-integrated).
  2. Estimates the noise floor (median power).
  3. Flags bins that rise THRESHOLD dB above the floor, groups contiguous
     hot bins into discrete signals, and reports center freq, peak power,
     SNR, and occupied bandwidth.
  4. Labels each hit with a likely service from a built-in allocation table.

Pure standard library — no numpy required.

Usage: analyze_scan.py <rtl_power.csv> <inventory_out.csv> [threshold_db]
"""
import csv
import sys
from collections import defaultdict

THRESHOLD_DB = 6.0      # how far above noise floor counts as a signal
MIN_SNR_REPORT = 3.0    # don't bother listing anything weaker than this

# (low_mhz, high_mhz, label) — first match wins; rough US allocations.
ALLOCATIONS = [
    (0.530, 1.700, "AM broadcast"),
    (1.8, 30.0, "HF / shortwave"),
    (88.0, 108.0, "FM broadcast"),
    (108.0, 118.0, "Aviation nav (VOR/ILS)"),
    (118.0, 137.0, "Airband (AM voice)"),
    (137.0, 138.0, "Weather sat / NOAA APT"),
    (144.0, 148.0, "2 m amateur"),
    (148.0, 150.8, "Govt / paging"),
    (150.8, 156.0, "VHF land mobile"),
    (156.0, 162.025, "VHF marine"),
    (162.4, 162.55, "NOAA weather radio"),
    (162.0, 174.0, "VHF land mobile / fed"),
    (174.0, 216.0, "VHF TV / DAB"),
    (225.0, 400.0, "Military UHF air"),
    (420.0, 450.0, "70 cm amateur"),
    (450.0, 470.0, "UHF land mobile"),
    (462.0, 468.0, "FRS / GMRS"),
    (470.0, 698.0, "UHF TV"),
    (824.0, 894.0, "Cellular 850"),
    (902.0, 928.0, "900 MHz ISM"),
    (929.0, 932.0, "POCSAG / FLEX paging"),
    (1090.0, 1090.1, "ADS-B transponder"),
]


def service_for(mhz: float) -> str:
    for lo, hi, label in ALLOCATIONS:
        if lo <= mhz <= hi:
            return label
    return "unallocated / unknown"


def load_power(path: str):
    """Return {bin_center_hz: [db, db, ...]} accumulated across all timestamps."""
    acc = defaultdict(list)
    step_hz = None
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if len(row) < 7:
                continue
            try:
                hz_low = float(row[2])
                step = float(row[4])
                vals = [float(x) for x in row[6:] if x.strip() != ""]
            except ValueError:
                continue
            step_hz = step
            for i, db in enumerate(vals):
                center = hz_low + step * (i + 0.5)
                acc[round(center)].append(db)
    return acc, step_hz


def median(xs):
    s = sorted(xs)
    n = len(s)
    if n == 0:
        return float("nan")
    m = n // 2
    return s[m] if n % 2 else (s[m - 1] + s[m]) / 2.0


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    raw, out = sys.argv[1], sys.argv[2]
    thresh = float(sys.argv[3]) if len(sys.argv) > 3 else THRESHOLD_DB

    acc, step_hz = load_power(raw)
    if not acc:
        print("No usable data in scan file.", file=sys.stderr)
        sys.exit(2)

    # Time-average each bin.
    freqs = sorted(acc)
    avg = {hz: sum(v) / len(v) for hz, v in acc.items()}

    floor = median(list(avg.values()))
    cutoff = floor + thresh

    # Walk bins in frequency order, grouping contiguous above-cutoff runs.
    # Allow a 1-bin gap so a slightly notched signal stays one group.
    signals = []
    i = 0
    n = len(freqs)
    gap_bins = 2
    while i < n:
        if avg[freqs[i]] < cutoff:
            i += 1
            continue
        j = i
        last_hot = i
        while j < n:
            if avg[freqs[j]] >= cutoff:
                last_hot = j
            elif j - last_hot > gap_bins:
                break
            j += 1
        group = freqs[i:last_hot + 1]
        peak_hz = max(group, key=lambda h: avg[h])
        peak_db = avg[peak_hz]
        bw_hz = (group[-1] - group[0]) + (step_hz or 0)
        snr = peak_db - floor
        if snr >= MIN_SNR_REPORT:
            signals.append({
                "freq_mhz": peak_hz / 1e6,
                "peak_dbfs": peak_db,
                "snr_db": snr,
                "bw_khz": bw_hz / 1e3,
                "service": service_for(peak_hz / 1e6),
            })
        i = last_hot + 1

    signals.sort(key=lambda s: s["snr_db"], reverse=True)

    # Write inventory CSV.
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["freq_mhz", "peak_dbfs", "snr_db", "bandwidth_khz", "likely_service"])
        for s in signals:
            w.writerow([f"{s['freq_mhz']:.4f}", f"{s['peak_dbfs']:.1f}",
                        f"{s['snr_db']:.1f}", f"{s['bw_khz']:.1f}", s["service"]])

    # Console report.
    lo_mhz = freqs[0] / 1e6
    hi_mhz = freqs[-1] / 1e6
    print(f"\nScan: {lo_mhz:.3f}–{hi_mhz:.3f} MHz   "
          f"bin={ (step_hz or 0)/1e3:.1f} kHz   "
          f"noise floor={floor:.1f} dB   threshold=+{thresh:.0f} dB")
    print(f"Found {len(signals)} signal(s):\n")
    if signals:
        print(f"  {'FREQ (MHz)':>12}  {'SNR':>6}  {'PEAK dB':>8}  {'BW kHz':>7}  SERVICE")
        print(f"  {'-'*12}  {'-'*6}  {'-'*8}  {'-'*7}  {'-'*24}")
        for s in signals:
            print(f"  {s['freq_mhz']:>12.4f}  {s['snr_db']:>5.1f}+  "
                  f"{s['peak_dbfs']:>8.1f}  {s['bw_khz']:>7.1f}  {s['service']}")
    else:
        print("  (nothing above threshold — try a longer dwell, higher gain,"
              " or a different band/antenna)")


if __name__ == "__main__":
    main()
