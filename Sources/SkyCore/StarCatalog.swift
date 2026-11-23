import Foundation

/// One catalogue star at the J2000.0 epoch.
public struct Star: Equatable, Sendable {
    /// Harvard Revised (HR) number from the Yale Bright Star Catalogue.
    public var hr: Int
    /// J2000 right ascension, degrees.
    public var rightAscension: Double
    /// J2000 declination, degrees.
    public var declination: Double
    /// Visual magnitude (smaller is brighter).
    public var magnitude: Double
    /// Approximate colour temperature, kelvin.
    public var temperature: Double
    /// Proper name, or Bayer/Flamsteed designation, or empty.
    public var name: String
}

/// A star placed in the observer's sky.
public struct VisibleStar: Sendable {
    public var star: Star
    public var horizontal: HorizontalCoordinates
}

/// The bundled Yale Bright Star Catalogue (about 9,100 stars down to magnitude 6.5),
/// sorted brightest first.
public final class StarCatalog: @unchecked Sendable {
    public let stars: [Star]

    public init(stars: [Star]) {
        self.stars = stars
    }

    /// Loads the catalogue shipped in the SkyCore bundle.
    public static func bundled() throws -> StarCatalog {
        guard let url = Bundle.module.url(forResource: "bsc5", withExtension: "csv") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try StarCatalog(csv: String(contentsOf: url, encoding: .utf8))
    }

    /// Parses `hr,ra_deg,dec_deg,vmag,kelvin,name` rows (header line first).
    public convenience init(csv: String) throws {
        var result: [Star] = []
        result.reserveCapacity(9_100)
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let f = line.split(separator: ",", maxSplits: 5, omittingEmptySubsequences: false)
            guard f.count >= 5,
                  let hr = Int(f[0]), let ra = Double(f[1]), let dec = Double(f[2]),
                  let mag = Double(f[3]), let k = Double(f[4]) else { continue }
            var name = f.count > 5 ? String(f[5]) : ""
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
            }
            result.append(Star(hr: hr, rightAscension: ra, declination: dec,
                               magnitude: mag, temperature: k, name: name))
        }
        self.init(stars: result)
    }

    /// Stars above the horizon for an observer and instant, brightest first.
    /// - Parameters:
    ///   - limitingMagnitude: faintest star to include (6.5 = naked eye under dark skies).
    ///   - minimumAltitude: lowest altitude to include, degrees.
    public func visibleStars(observer: Observer, at date: Date,
                             limitingMagnitude: Double = 6.5,
                             minimumAltitude: Double = -1) -> [VisibleStar] {
        let jd = AstroMath.julianDay(date)
        let precession = Precession(fromJ2000To: jd)
        var out: [VisibleStar] = []
        for star in stars {
            if star.magnitude > limitingMagnitude { break } // sorted brightest first
            let eq = precession.apply(rightAscension: star.rightAscension, declination: star.declination)
            let hz = observer.horizontal(rightAscension: eq.rightAscension, declination: eq.declination, jd: jd)
            if hz.altitude >= minimumAltitude {
                out.append(VisibleStar(star: star, horizontal: hz))
            }
        }
        return out
    }
}

/// Rigorous precession of equatorial coordinates from J2000.0 to a date (Meeus ch. 21).
/// Precompute once per frame, then apply to every star.
public struct Precession: Sendable {
    private let zeta: Double, z: Double, theta: Double

    public init(fromJ2000To jd: Double) {
        let t = AstroMath.julianCentury(jd)
        // Arcseconds -> degrees.
        zeta = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) / 3600
        z = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) / 3600
        theta = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) / 3600
    }

    public func apply(rightAscension ra0: Double, declination dec0: Double)
        -> (rightAscension: Double, declination: Double)
    {
        let a = AstroMath.cosd(dec0) * AstroMath.sind(ra0 + zeta)
        let b = AstroMath.cosd(theta) * AstroMath.cosd(dec0) * AstroMath.cosd(ra0 + zeta)
            - AstroMath.sind(theta) * AstroMath.sind(dec0)
        let c = AstroMath.sind(theta) * AstroMath.cosd(dec0) * AstroMath.cosd(ra0 + zeta)
            + AstroMath.cosd(theta) * AstroMath.sind(dec0)
        let ra = AstroMath.normalize(AstroMath.atan2d(a, b) + z)
        let dec = AstroMath.asind(max(-1, min(1, c)))
        return (ra, dec)
    }
}

/// Approximate sRGB colour (0...1 components) of a black body, for tinting stars.
public func blackBodyColor(kelvin: Double) -> (red: Double, green: Double, blue: Double) {
    let t = max(1_000, min(40_000, kelvin)) / 100
    let r: Double = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
    let g: Double = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661
                            : 288.1221695283 * pow(t - 60, -0.0755148492)
    let b: Double = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
    let clamp = { (x: Double) in max(0, min(255, x)) / 255 }
    return (clamp(r), clamp(g), clamp(b))
}
