# Sky

A macOS menu bar app that paints a live sky behind your desktop icons: the Sun where it really is
for your location and time, the real night sky from the Yale Bright Star Catalogue, and clouds,
rain and snow from the current weather.

All astronomy runs locally. Only the weather (Open-Meteo, every 15 minutes) uses the network,
and the last result is cached so the sky keeps working offline.

## Build and run

Requires macOS 14+ and Xcode 15+ (or the Swift 5.9+ toolchain).

```sh
swift test                 # astronomy + weather tests (also run on Linux)
swift run SkyWallpaper     # launches the menu bar app and the desktop sky
```

Or open `Package.swift` in Xcode and run the `SkyWallpaper` scheme. Use the sun-and-horizon
menu bar icon to open Settings, set your coordinates, and scrub through the day or the seasons.

## Display modes

Choose in Settings: **Live sky** (default, animated window behind the icons), **Still image**
(sets a rendered picture as the normal wallpaper every 5 minutes), or **Live, still on battery**.
Your own wallpaper is put back when Sky quits.

![London, 21 June 2026, through the day](Docs/london-midsummer-day.png)

## Layout

| Path | What it is |
| --- | --- |
| `Sources/SkyCore/AstroMath.swift` | Julian day, sidereal time, refraction, equatorial to horizontal |
| `Sources/SkyCore/SolarCalculator.swift` | NOAA / Meeus sun position, sunrise, sunset, twilight, polar day and night |
| `Sources/SkyCore/StarCatalog.swift` | Bundled Bright Star Catalogue, precession from J2000, star colours |
| `Sources/SkyCore/Weather.swift` | `WeatherProvider` protocol, Open-Meteo client, caching `WeatherService` |
| `Sources/SkyCore/Atmosphere.swift` | Preetham daylight sky model, screen projection, low-res sky background renderer |
| `Sources/SkyCore/SkyScene.swift` | Combines sun, stars and weather into one frame's scene and sky colours |
| `Sources/SkyWallpaper/` | The app: live desktop windows, still-image wallpaper mode, renderer, settings |
| `Scripts/build_star_catalog.py` | Regenerates `Resources/bsc5.csv` from the catalogue JSON |

## Accuracy

Unit tests check the maths against worked examples in Meeus, *Astronomical Algorithms*
(sun coordinates 25.a, equation of time 28.a, sidereal time 12.a, precession 21.b) and against
published 2026 sunrise and sunset times for London and Sydney, plus polar day and night at Tromsø.
Sun position is good to about 0.01° and rise/set times to about a minute. Stellar proper motion
is not applied yet (under 0.1° for every bright star over a century, invisible at wallpaper scale).

## Data

Star data: Yale Bright Star Catalogue, 5th revised edition (Hoffleit & Warren 1991, CDS V/50),
converted from the JSON transcription at github.com/brettonw/YaleBrightStarCatalog.
Weather: [Open-Meteo](https://open-meteo.com/), free for non-commercial use (CC BY 4.0 attribution).

## Roadmap

1. Scaffold, astronomy and weather model (this commit)
2. Daytime sky: Preetham scattering model, sun disc, display modes (merged)
3. Seasonal view width: wide enough to show sunrise and sunset all year (this branch)
4. Night sky: Moon with phase, planets, Milky Way
5. Weather in Metal: volumetric-looking cloud layers lit by the Sun, rain on glass, fog, lightning
6. Multi-display, power saving, launch at login, still-image mode
