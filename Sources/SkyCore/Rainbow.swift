import Foundation

/// Rainbows: sunlight refracted and reflected inside falling raindrops. The bow is a circle
/// centred on the antisolar point (directly opposite the Sun, below the horizon when the Sun
/// is up): the primary bow 40.5–42.4° from it with red outside, a fainter secondary bow
/// 50–53.5° out with the colours reversed, a brighter sky inside the primary, and the darker
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

    /// Light added at `angle` degrees from the antisolar point, as RGB (before strength).
    static func light(atAngle t: Double) -> (Double, Double, Double) {
        func band(_ centre: Double, _ width: Double) -> Double { exp(-pow((t - centre) / width, 2)) }
        // Primary: red outermost. Secondary: reversed and fainter.
        var r = band(42.1, 0.55) + 0.42 * band(50.6, 0.8)
        var g = band(41.3, 0.55) + 0.42 * band(51.5, 0.8)
        var b = band(40.6, 0.55) + 0.42 * band(52.5, 0.8)
        // The sky inside the primary bow is brighter, fading towards the centre.
        let inside = t < 40.4 ? 0.10 * exp(-(40.4 - t) / 9) : 0
        r += inside; g += inside; b += inside
        return (r * 0.9, g * 0.85, b * 0.95)
    }

    /// The bow as premultiplied RGBA to add over the sky, or nil if none shows on screen.
    public static func render(scene: SkyScene, projection: SkyProjection, width: Int, height: Int) -> RGBAImage? {
        let s = strength(weather: scene.weather, sunAltitude: scene.sun.horizontal.altitude)
        guard s > 0.01 else { return nil }
        let anti = HorizontalCoordinates(altitude: -scene.sun.horizontal.altitude,
                                         azimuth: AstroMath.normalize(scene.sun.horizontal.azimuth + 180))
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let sx = projection.width / Double(width), sy = projection.height / Double(height)
        var any = false
        for j in 0..<height {
            for i in 0..<width {
                let dir = projection.direction(x: (Double(i) + 0.5) * sx, y: (Double(j) + 0.5) * sy)
                guard dir.altitude > -0.5 else { continue }
                let t = separation(dir, anti)
                guard t > 25, t < 56 else { continue }
                // Rain falls from the cloud base, so the bow fades higher up the sky.
                let curtain = 1 - smoothstep(25, 45, dir.altitude)
                let k = s * 0.55 * curtain * smoothstep(-0.5, 1, dir.altitude)
                let (r, g, b) = light(atAngle: t)
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
