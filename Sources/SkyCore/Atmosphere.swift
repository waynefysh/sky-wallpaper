import Foundation

/// Analytic daylight sky model from Preetham, Shirley & Smits, "A Practical Analytic Model
/// for Daylight" (SIGGRAPH 1999). Gives sky luminance and colour in any direction from the
/// Sun's position and the atmosphere's turbidity (haze). Valid while the Sun is above the
/// horizon; `SkyGradientRenderer` blends it into keyframed twilight colours near sunset.
public struct PreethamSky: Sendable {
    /// 2 = very clear mountain air, 3 = clear, 6 = hazy, 10 = thin fog.
    public let turbidity: Double
    /// Sun zenith angle, radians (0 = overhead, π/2 = on the horizon).
    public let sunZenith: Double

    private let perezY: [Double], perezX: [Double], perezYc: [Double]
    private let zenithY: Double, zenithX: Double, zenithYc: Double
    private let normY: Double, normX: Double, normYc: Double

    public init(turbidity: Double, sunZenith: Double) {
        let t = turbidity
        let ts = min(sunZenith, Double.pi / 2 - 0.001)
        self.turbidity = t
        self.sunZenith = ts

        perezY = [0.1787 * t - 1.4630, -0.3554 * t + 0.4275, -0.0227 * t + 5.3251,
                  0.1206 * t - 2.5771, -0.0670 * t + 0.3703]
        perezX = [-0.0193 * t - 0.2592, -0.0665 * t + 0.0008, -0.0004 * t + 0.2125,
                  -0.0641 * t - 0.8989, -0.0033 * t + 0.0452]
        perezYc = [-0.0167 * t - 0.2608, -0.0950 * t + 0.0092, -0.0079 * t + 0.2102,
                   -0.0441 * t - 1.6537, -0.0109 * t + 0.0529]

        let chi = (4.0 / 9.0 - t / 120.0) * (Double.pi - 2 * ts)
        zenithY = (4.0453 * t - 4.9710) * tan(chi) - 0.2155 * t + 2.4192 // kcd/m²
        let t3 = ts * ts * ts, t2 = ts * ts
        zenithX = (0.00166 * t3 - 0.00375 * t2 + 0.00209 * ts) * t * t
            + (-0.02903 * t3 + 0.06377 * t2 - 0.03202 * ts + 0.00394) * t
            + (0.11693 * t3 - 0.21196 * t2 + 0.06052 * ts + 0.25886)
        zenithYc = (0.00275 * t3 - 0.00610 * t2 + 0.00317 * ts) * t * t
            + (-0.04214 * t3 + 0.08970 * t2 - 0.04153 * ts + 0.00516) * t
            + (0.15346 * t3 - 0.26756 * t2 + 0.06670 * ts + 0.26688)

        normY = Self.perez(0, ts, perezY)
        normX = Self.perez(0, ts, perezX)
        normYc = Self.perez(0, ts, perezYc)
    }

    /// Luminance of the zenith in kcd/m².
    public var zenithLuminance: Double { zenithY }

    /// CIE xyY of the sky.
    /// - Parameters:
    ///   - theta: view zenith angle, radians (clamped just above the horizon).
    ///   - gamma: angle between the view direction and the Sun, radians.
    public func xyY(theta: Double, gamma: Double) -> (x: Double, y: Double, Y: Double) {
        let th = min(theta, Double.pi / 2 - 0.001)
        return (zenithX * Self.perez(th, gamma, perezX) / normX,
                zenithYc * Self.perez(th, gamma, perezYc) / normYc,
                zenithY * Self.perez(th, gamma, perezY) / normY)
    }

    /// Display-ready sRGB-encoded colour (0...1), exposure-normalised to the zenith so the
    /// sky keeps a pleasant brightness at every solar altitude.
    public func displayColor(theta: Double, gamma: Double,
                             exposure: Double = 0.9, saturation: Double = 1.5) -> SkyColor {
        let c = xyY(theta: theta, gamma: gamma)
        let yy = max(c.y, 1e-4)
        let X = c.x / yy * c.Y, Y = c.Y, Z = (1 - c.x - c.y) / yy * c.Y
        // XYZ -> linear sRGB, normalised by zenith luminance.
        var r = max(0, 3.2406 * X - 1.5372 * Y - 0.4986 * Z) / zenithY
        var g = max(0, -0.9689 * X + 1.8758 * Y + 0.0415 * Z) / zenithY
        var b = max(0, 0.0557 * X - 0.2040 * Y + 1.0570 * Z) / zenithY
        // Gentle saturation boost: Preetham's chromaticities come out pale on screens.
        var lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r = max(0, lum + (r - lum) * saturation)
        g = max(0, lum + (g - lum) * saturation)
        b = max(0, lum + (b - lum) * saturation)
        // Tone-map luminance only, which keeps the hue and avoids yellow clipping near the Sun.
        lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let scale = lum > 1e-6 ? (1 - exp(-lum * exposure)) / lum : 0
        r *= scale; g *= scale; b *= scale
        let m = max(r, g, b)
        if m > 1 { r /= m; g /= m; b /= m }
        return SkyColor(srgbEncode(r), srgbEncode(g), srgbEncode(b))
    }

    static func perez(_ theta: Double, _ gamma: Double, _ c: [Double]) -> Double {
        let cosT = max(cos(theta), 0.01)
        let cosG = cos(gamma)
        return (1 + c[0] * exp(c[1] / cosT)) * (1 + c[2] * exp(c[3] * gamma) + c[4] * cosG * cosG)
    }

    /// Turbidity from visibility in metres: clear air about 2.2, hazy about 6, fog towards 10.
    public static func turbidity(visibility: Double?) -> Double {
        guard let v = visibility, v > 0 else { return 2.8 }
        return max(2.0, min(10.0, 2.0 + 25_000 / v))
    }
}

@inline(__always) func srgbEncode(_ c: Double) -> Double {
    let x = max(0, min(1, c))
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
}

@inline(__always) func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}

/// Maps between screen positions and sky directions. The default view faces the equator
/// (south in the northern hemisphere), so the Sun rises at the left and sets at the right.
public struct SkyProjection: Sendable {
    public var width: Double
    public var height: Double
    public var facingAzimuth: Double
    public var horizontalFOV: Double = 140
    public var lowestAltitude: Double = -4
    public var highestAltitude: Double = 66

    public init(width: Double, height: Double, facingAzimuth: Double, horizontalFOV: Double = 140) {
        self.width = width
        self.height = height
        self.facingAzimuth = facingAzimuth
        self.horizontalFOV = horizontalFOV
    }

    /// The direction the view faces by default: towards the equator, where the Sun is at noon.
    public static func equatorFacingAzimuth(for observer: Observer) -> Double {
        observer.latitude >= 0 ? 180 : 0
    }

    /// A horizontal field of view wide enough to keep the day's sunrise and sunset on screen.
    /// Near midsummer away from the tropics the Sun rises and sets behind a viewer facing the
    /// equator, so the view widens with the seasons: about 140° in winter, up to 300° in summer.
    public static func seasonalFieldOfView(observer: Observer, date: Date, timeZone: TimeZone = .current,
                                           minimum: Double = 140, maximum: Double = 300,
                                           margin: Double = 12) -> Double {
        let calc = SolarCalculator(observer: observer)
        let day = calc.day(containing: date, timeZone: timeZone)
        if day.isPolarDay { return maximum }
        guard let rise = day.sunrise, let set = day.sunset else { return minimum }
        let facing = equatorFacingAzimuth(for: observer)
        let spread = [rise, set]
            .map { abs(AstroMath.normalizeSigned(calc.position(at: $0).horizontal.azimuth - facing)) }
            .max() ?? 0
        return max(minimum, min(maximum, 2 * (spread + margin)))
    }

    /// Screen point (origin top-left) for a sky direction, or nil if well off screen.
    public func point(_ h: HorizontalCoordinates) -> (x: Double, y: Double)? {
        let dAz = AstroMath.normalizeSigned(h.azimuth - facingAzimuth)
        guard abs(dAz) <= horizontalFOV / 2 + 5 else { return nil }
        return ((dAz / horizontalFOV + 0.5) * width,
                (1 - (h.altitude - lowestAltitude) / (highestAltitude - lowestAltitude)) * height)
    }

    /// Sky direction for a screen point (origin top-left).
    public func direction(x: Double, y: Double) -> HorizontalCoordinates {
        HorizontalCoordinates(
            altitude: highestAltitude - (y / height) * (highestAltitude - lowestAltitude),
            azimuth: AstroMath.normalize(facingAzimuth + (x / width - 0.5) * horizontalFOV))
    }
}

/// Renders the sky background into a small RGBA buffer. The sky is smooth, so a buffer of
/// about 96 × 64 pixels scaled up with smoothing looks identical to a full-resolution one.
public struct SkyGradientRenderer: Sendable {
    public init() {}

    /// - Returns: `width * height * 4` bytes, RGBA, premultiplied (alpha is always 255), top row first.
    public func render(scene: SkyScene, projection: SkyProjection,
                       width: Int, height: Int) -> [UInt8] {
        let sunAlt = scene.sun.horizontal.altitude
        let sunAz = scene.sun.horizontal.azimuth
        let turbidity = PreethamSky.turbidity(visibility: scene.weather.visibility)
        let model = PreethamSky(turbidity: turbidity, sunZenith: (90 - max(sunAlt, 0)) * AstroMath.deg2rad)
        // How much of the analytic daylight model to use: none below the horizon,
        // all of it once the Sun is 8° up. Twilight keyframes fill the rest.
        let dayWeight = smoothstep(-1, 8, sunAlt)
        let dim = 0.8 + 0.2 * smoothstep(0, 30, sunAlt)

        let sun = unitVector(altitude: sunAlt, azimuth: sunAz)
        var out = [UInt8](repeating: 255, count: width * height * 4)
        let sx = projection.width / Double(width), sy = projection.height / Double(height)

        // Night extras: the Milky Way (when dark and clear) and moonlight brightening the sky.
        let cloud = max(scene.weather.cloudLow, scene.weather.cloudMid * 0.8, scene.weather.cloudHigh * 0.4)
        let moonUp = scene.moon.horizontal.altitude > 0
        let moonlight = moonUp ? scene.moon.illuminatedFraction * smoothstep(0, 20, scene.moon.horizontal.altitude)
            * (1 - smoothstep(-8, -2, sunAlt)) : 0
        let milkyWay = scene.starVisibility * scene.starVisibility * (1 - cloud) * (1 - 0.7 * moonlight)
        let jd = AstroMath.julianDay(scene.date)
        let lst = AstroMath.normalize(AstroMath.greenwichMeanSiderealTime(jd: jd) + scene.observer.longitude)
        let lat = scene.observer.latitude
        // Twilight colours sit on the Sun's side; the opposite horizon stays nearer the zenith colour.
        let awayHorizon = SkyColor.mix(scene.zenithColor, scene.horizonColor, 0.4)

        for j in 0..<height {
            for i in 0..<width {
                let dir = projection.direction(x: (Double(i) + 0.5) * sx, y: (Double(j) + 0.5) * sy)
                let alt = max(dir.altitude, 0)
                let fromSun = abs(AstroMath.normalizeSigned(dir.azimuth - sunAz))
                let horizon = SkyColor.mix(scene.horizonColor, awayHorizon, smoothstep(50, 160, fromSun))
                var c = SkyColor.mix(horizon, scene.zenithColor, smoothstep(0, 55, alt))
                if moonlight > 0 {
                    c = SkyColor.mix(c, SkyColor(0.10, 0.16, 0.30), 0.35 * moonlight)
                }
                if milkyWay > 0.01, dir.altitude > 0 {
                    // Horizontal -> equatorial (of date; precession is invisible at this scale) -> galactic.
                    let sinDec = AstroMath.sind(alt) * AstroMath.sind(lat)
                        + AstroMath.cosd(alt) * AstroMath.cosd(lat) * AstroMath.cosd(dir.azimuth)
                    let dec = AstroMath.asind(max(-1, min(1, sinDec)))
                    let ha = AstroMath.atan2d(-AstroMath.sind(dir.azimuth) * AstroMath.cosd(alt),
                                              AstroMath.sind(alt) * AstroMath.cosd(lat)
                                                - AstroMath.cosd(alt) * AstroMath.sind(lat) * AstroMath.cosd(dir.azimuth))
                    let g = Galactic.fromEquatorial(rightAscension: AstroMath.normalize(lst - ha), declination: dec)
                    let v = Galactic.milkyWayBrightness(longitude: g.longitude, latitude: g.latitude)
                        * milkyWay * smoothstep(0, 25, alt) * 0.16
                    c = SkyColor(c.r + v * 0.95, c.g + v * 0.97, c.b + v)
                }
                if dayWeight > 0 {
                    let v = unitVector(altitude: alt, azimuth: dir.azimuth)
                    let cosG = max(-1, min(1, v.0 * sun.0 + v.1 * sun.1 + v.2 * sun.2))
                    var d = model.displayColor(theta: (90 - alt) * AstroMath.deg2rad, gamma: acos(cosG))
                    d = SkyColor(d.r * dim, d.g * dim, d.b * dim)
                    c = SkyColor.mix(c, d, dayWeight)
                }
                if dir.altitude < 0 { // below the horizon: a darker band for the ground haze
                    let k = 0.55 + 0.45 * (1 + dir.altitude / 4) * 0.4
                    c = SkyColor(c.r * k, c.g * k, c.b * k)
                }
                let o = (j * width + i) * 4
                out[o] = UInt8(max(0, min(255, c.r * 255)))
                out[o + 1] = UInt8(max(0, min(255, c.g * 255)))
                out[o + 2] = UInt8(max(0, min(255, c.b * 255)))
            }
        }
        return out
    }

    private func unitVector(altitude: Double, azimuth: Double) -> (Double, Double, Double) {
        let ca = AstroMath.cosd(altitude)
        return (ca * AstroMath.sind(azimuth), ca * AstroMath.cosd(azimuth), AstroMath.sind(altitude))
    }
}
