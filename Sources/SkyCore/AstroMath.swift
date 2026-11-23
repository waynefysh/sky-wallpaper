import Foundation

/// Small angle and time helpers shared by the astronomy code.
/// All public angles are in degrees unless the name says otherwise.
public enum AstroMath {
    public static let deg2rad = Double.pi / 180
    public static let rad2deg = 180 / Double.pi

    @inline(__always) public static func sind(_ x: Double) -> Double { sin(x * deg2rad) }
    @inline(__always) public static func cosd(_ x: Double) -> Double { cos(x * deg2rad) }
    @inline(__always) public static func tand(_ x: Double) -> Double { tan(x * deg2rad) }
    @inline(__always) public static func asind(_ x: Double) -> Double { asin(x) * rad2deg }
    @inline(__always) public static func acosd(_ x: Double) -> Double { acos(x) * rad2deg }
    @inline(__always) public static func atan2d(_ y: Double, _ x: Double) -> Double { atan2(y, x) * rad2deg }

    /// Wraps an angle into [0, 360).
    public static func normalize(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Wraps an angle into [-180, 180).
    public static func normalizeSigned(_ degrees: Double) -> Double {
        let r = normalize(degrees)
        return r >= 180 ? r - 360 : r
    }

    /// Julian Day for a Foundation date (UTC). Unix epoch is JD 2440587.5.
    public static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    /// Date for a Julian Day.
    public static func date(fromJulianDay jd: Double) -> Date {
        Date(timeIntervalSince1970: (jd - 2_440_587.5) * 86_400)
    }

    /// Julian centuries since J2000.0.
    public static func julianCentury(_ jd: Double) -> Double {
        (jd - 2_451_545.0) / 36_525.0
    }

    /// Greenwich mean sidereal time in degrees (Meeus eq. 12.4).
    public static func greenwichMeanSiderealTime(jd: Double) -> Double {
        let t = julianCentury(jd)
        let gmst = 280.46061837
            + 360.98564736629 * (jd - 2_451_545.0)
            + 0.000387933 * t * t
            - t * t * t / 38_710_000.0
        return normalize(gmst)
    }

    /// Atmospheric refraction in degrees to add to a true (geometric) altitude.
    /// Saemundsson's formula (Meeus eq. 16.4), with the usual temperature/pressure defaults.
    public static func refraction(trueAltitude h: Double) -> Double {
        guard h > -1.9 else { return 0 }
        let r = 1.02 / tand(h + 10.3 / (h + 5.11)) // arcminutes
        return max(r, 0) / 60
    }
}

/// A direction in the observer's local sky.
public struct HorizontalCoordinates: Equatable, Sendable {
    /// Degrees above the horizon (negative = below). Includes refraction when apparent.
    public var altitude: Double
    /// Degrees clockwise from true north (0 = N, 90 = E, 180 = S, 270 = W).
    public var azimuth: Double

    public init(altitude: Double, azimuth: Double) {
        self.altitude = altitude
        self.azimuth = azimuth
    }
}

/// An observer on the Earth.
public struct Observer: Equatable, Sendable, Codable {
    /// Degrees, north positive.
    public var latitude: Double
    /// Degrees, east positive.
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Local apparent position of an object at equatorial coordinates (of date).
    public func horizontal(rightAscension ra: Double, declination dec: Double, jd: Double,
                           applyRefraction: Bool = true) -> HorizontalCoordinates {
        let lst = AstroMath.normalize(AstroMath.greenwichMeanSiderealTime(jd: jd) + longitude)
        let ha = AstroMath.normalizeSigned(lst - ra)
        return Observer.horizontal(hourAngle: ha, declination: dec, latitude: latitude,
                                   applyRefraction: applyRefraction)
    }

    static func horizontal(hourAngle ha: Double, declination dec: Double, latitude lat: Double,
                           applyRefraction: Bool) -> HorizontalCoordinates {
        let sinAlt = AstroMath.sind(lat) * AstroMath.sind(dec)
            + AstroMath.cosd(lat) * AstroMath.cosd(dec) * AstroMath.cosd(ha)
        var alt = AstroMath.asind(max(-1, min(1, sinAlt)))
        // Azimuth measured from north, eastwards.
        let az = AstroMath.normalize(
            AstroMath.atan2d(AstroMath.sind(ha),
                             AstroMath.cosd(ha) * AstroMath.sind(lat) - AstroMath.tand(dec) * AstroMath.cosd(lat)) + 180
        )
        if applyRefraction { alt += AstroMath.refraction(trueAltitude: alt) }
        return HorizontalCoordinates(altitude: alt, azimuth: az)
    }
}
