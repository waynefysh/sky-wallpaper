import Foundation

/// Rainbows: sunlight refracted and reflected inside falling raindrops. The bow is a circle
/// centred on the antisolar point (directly opposite the Sun, below the horizon when the Sun
/// is up): the primary bow 40.5–42.4° from it with red outside, a fainter secondary bow
/// 50–53.5° out with the colours reversed (often missing, and faint when it shows), a brighter sky inside the primary, and the darker
/// Alexander's band between the two. It needs the Sun low (under 42°), shining, and rain
/// falling on the far side of the sky.
public enum Rainbow {
    /// How strongly a rainbow shows, 0...1, for the weather and the Sun's altitude.
    public static func strength(weather: WeatherConditions, sunAltitude h: Double) -> Double {
        guard weather.precipitation == .rain || weather.precipitation == .drizzle else { return 0 }
        let sunUp = smoothstep(-0.5, 1.5, h) * (1 - smoothstep(38, 42, h))
        // The Sun has to get through: showers with broken cloud, not a solid rain deck.
        let broken = 1 - smoothstep(0.6, 0.9, weather.cloudLow)
        let rain = weather.precipitation == .drizzle ? 0.6 : 1
        return sunUp * broken * rain
    }

    /// Angular distance (degrees) between two sky directions.
    static func separation(_ a: HorizontalCoordinates, _ b: HorizontalCoordinates) -> Double {
        let c = AstroMath.sind(a.altitude) * AstroMath.sind(b.altitude)
            + AstroMath.cosd(a.altitude) * AstroMath.cosd(b.altitude) * AstroMath.cosd(a.azimuth - b.azimuth)
        return AstroMath.acosd(max(-1, min(1, c)))
    }

    /// Wavelength samples from deep red to violet: each one's primary-bow angle from the
    /// antisolar point (degrees) and its colour. Together they blend into a continuous band.
    private static let spectrum: [(angle: Double, r: Double, g: Double, b: Double)] = [
        (42.37, 1, 0, 0), (42.25, 1, 0.1, 0), (42.10, 1, 0.45, 0), (41.90, 0.9, 0.85, 0),
        (41.70, 0.45, 1, 0.1), (41.45, 0.1, 0.9, 0.4), (41.20, 0, 0.6, 0.85),
        (40.95, 0.1, 0.3, 1), (40.70, 0.4, 0.1, 0.95), (40.50, 0.35, 0, 0.6),
    ]

    /// Light added at `angle` degrees from the antisolar point, as RGB (before strength).
    /// `secondary` is how strongly the outer bow shows, relative to the primary (0 for none).
    static func light(atAngle t: Double, secondary: Double = 0.3) -> (Double, Double, Double) {
        guard t > 34, t < 57 else {
            let inside = t <= 34 ? 0.12 * exp(-(40.3 - t) / 7) : 0
            return (inside, inside, inside)
        }
        var r = 0.0, g = 0.0, b = 0.0
        for s in spectrum {
            // Each colour is smeared by the Sun's disc and the spread of drop sizes.
            var w = exp(-pow((t - s.angle) / 0.45, 2))
            // The secondary bow: reversed, wider, and only as strong as `secondary`.
            if secondary > 0 {
                let a2 = 50.4 + (42.37 - s.angle) * 1.6
                w += secondary * exp(-pow((t - a2) / 0.6, 2))
            }
            r += w * s.r; g += w * s.g; b += w * s.b
        }
        r /= 3.56; g /= 3.56; b /= 3.56
        // Soften towards pastel: real bows are washed out by the bright sky behind them.
        let grey = (r + g + b) / 3
        r += (grey - r) * 0.2; g += (grey - g) * 0.2; b += (grey - b) * 0.2
        // The sky inside the primary bow is brighter, fading towards the centre.
        let inside = 0.12 * exp(-max(0, 40.3 - t) / 7) * (1 - smoothstep(40.0, 40.8, t))
        return (r + inside, g + inside, b + inside)
    }

    /// How strongly the secondary bow shows in the shower at `date`, 0 when there is none.
    /// It is chosen once per half hour, so it does not flicker: about half of showers show
    /// none, the rest a faint one, and only heavy showers with a low Sun a clearer one.
    static func secondaryStrength(weather: WeatherConditions, sunAltitude h: Double, date: Date) -> Double {
        let slot = UInt64(max(0, date.timeIntervalSinceReferenceDate / 1800))
        var rng = SplitMix(seed: slot &* 0x9E37_79B9 &+ 17)
        let roll = rng.unit()
        let heavy = smoothstep(1, 6, weather.precipitationRate)
        let low = 1 - smoothstep(10, 30, h)
        let chance = 0.35 + 0.3 * heavy * low
        guard roll < chance, weather.precipitation == .rain else { return 0 }
        return 0.12 + 0.18 * heavy * low * rng.unit()
    }

    /// The bow as premultiplied RGBA to add over the sky, or nil if none shows on screen.
    public static func render(scene: SkyScene, projection: SkyProjection, width: Int, height: Int) -> RGBAImage? {
        let h = scene.sun.horizontal.altitude
        let s = strength(weather: scene.weather, sunAltitude: h)
        guard s > 0.01 else { return nil }
        let secondary = secondaryStrength(weather: scene.weather, sunAltitude: h, date: scene.date)
        let anti = HorizontalCoordinates(altitude: -h, azimuth: AstroMath.normalize(scene.sun.horizontal.azimuth + 180))
        // Patches along the arc where the rain is heavier or shaded by cloud. They drift
        // slowly, so parts of the bow come and go as the showers move.
        let slot = UInt32(truncatingIfNeeded: Int(scene.date.timeIntervalSinceReferenceDate / 1800))
        let noise = GradientNoise(seed: slot &* 2_654_435_761 &+ 11)
        let drift = scene.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1800) / 900
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let sx = projection.width / Double(width), sy = projection.height / Double(height)
        var any = false
        for j in 0..<height {
            for i in 0..<width {
                let dir = projection.direction(x: (Double(i) + 0.5) * sx, y: (Double(j) + 0.5) * sy)
                guard dir.altitude > -0.5 else { continue }
                let t = separation(dir, anti)
                guard t > 25, t < 56 else { continue }
                // Rain falls from the cloud base, so the bow is strongest low down and fades
                // well before the top of the arch.
                let curtain = 1 - smoothstep(6, 34, dir.altitude)
                // Position around the arch: -90° one leg, 0 the top, 90° the other leg.
                let around = atan2(AstroMath.normalizeSigned(dir.azimuth - anti.azimuth) * AstroMath.cosd(dir.altitude),
                                   dir.altitude - anti.altitude) * 180 / .pi
                let n = noise.noise(around / 38 + 3.7, drift + 1.3) + 0.4 * noise.noise(around / 12 + 9.1, drift * 1.7 + 5.2)
                let patch = 0.25 + 0.75 * smoothstep(-0.35, 0.35, n)
                let k = s * 0.3 * curtain * patch * smoothstep(-0.5, 1, dir.altitude)
                let (r, g, b) = light(atAngle: t, secondary: secondary)
                let o = (j * width + i) * 4
                out[o] = UInt8(max(0, min(255, r * k * 255)))
                out[o + 1] = UInt8(max(0, min(255, g * k * 255)))
                out[o + 2] = UInt8(max(0, min(255, b * k * 255)))
                out[o + 3] = 255
                if out[o] > 2 { any = true }
            }
        }
        return any ? RGBAImage(width: width, height: height, pixels: out) : nil
    }
}

extension Rainbow {
    /// Whether a bow would stand in the middle part of the equator-facing view at `date`:
    /// the Sun 6–30° up, and the whole arch (42° either side of the point opposite it) inside the view.
    public static func isInView(observer: Observer, at date: Date, fieldOfView: Double) -> Bool {
        let sun = SolarCalculator(observer: observer).position(at: date).horizontal
        guard sun.altitude > 6, sun.altitude < 30 else { return false }
        let anti = AstroMath.normalize(sun.azimuth + 180)
        let face = SkyProjection.equatorFacingAzimuth(for: observer)
        return abs(AstroMath.normalizeSigned(anti - face)) < fieldOfView / 2 - 45
    }

    /// The first moment after `date` (searching up to a year, in 10-minute steps) when a
    /// rainbow would be in view, for previewing one. Nil if there is none (e.g. near the poles).
    public static func nextChanceInView(observer: Observer, after date: Date, timeZone: TimeZone = .current) -> Date? {
        var day = date
        for _ in 0..<366 {
            let fov = SkyProjection.seasonalFieldOfView(observer: observer, date: day, timeZone: timeZone)
            var t = day
            let end = day.addingTimeInterval(86_400)
            while t < end {
                if isInView(observer: observer, at: t, fieldOfView: fov) { return t }
                t.addTimeInterval(600)
            }
            day = end
        }
        return nil
    }
}
