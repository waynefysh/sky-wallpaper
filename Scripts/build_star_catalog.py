#!/usr/bin/env python3
"""Convert the Yale Bright Star Catalogue (5th ed.) JSON into the compact CSV the app bundles.

Input: bsc5-short.json from https://github.com/brettonw/YaleBrightStarCatalog
(a JSON transcription of CDS catalogue V/50, Hoffleit & Warren 1991).
Output columns: hr, ra_deg, dec_deg, vmag, kelvin, name   (J2000 equatorial).
Usage: python3 Scripts/build_star_catalog.py bsc5-short.json Sources/SkyCore/Resources/bsc5.csv
"""
import csv, json, re, sys

def ra_deg(s):
    h, m, sec = map(float, re.findall(r"[\d.]+", s))
    return 15 * (h + m / 60 + sec / 3600)

def dec_deg(s):
    sign = -1 if s.strip().startswith("-") else 1
    d, m, sec = map(float, re.findall(r"[\d.]+", s))
    return sign * (d + m / 60 + sec / 3600)

def main(src, dst):
    stars = json.load(open(src, encoding="utf-8"))
    rows = []
    for s in stars:
        try:
            v = float(s["V"])
        except (KeyError, ValueError):
            continue
        name = s.get("N") or " ".join(x for x in (s.get("B") or s.get("F"), s.get("C")) if x)
        rows.append((int(s["HR"]), round(ra_deg(s["RA"]), 5), round(dec_deg(s["Dec"]), 5), v,
                     int(s.get("K") or 6000), name))
    rows.sort(key=lambda r: r[3])  # brightest first, so the renderer can cut at any magnitude
    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["hr", "ra_deg", "dec_deg", "vmag", "kelvin", "name"])
        w.writerows(rows)
    print(f"wrote {len(rows)} stars to {dst}")

if __name__ == "__main__":
    main(*sys.argv[1:3])
