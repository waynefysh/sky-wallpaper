import Foundation

/// A naked-eye planet placed in the observer's sky.
public struct PlanetState: Sendable {
    public var planet: Planet
    public var rightAscension: Double
    public var declination: Double
    /// Distance from the Earth, AU.
    public var distance: Double
    /// Approximate visual magnitude.
    public var magnitude: Double
    public var horizontal: HorizontalCoordinates
}

public enum Planet: String, CaseIterable, Sendable {
    case mercury, venus, mars, jupiter, saturn

    public var name: String { rawValue.capitalized }

    /// Approximate colour for drawing.
    public var color: SkyColor {
        switch self {
        case .mercury: return SkyColor(0.85, 0.82, 0.78)
        case .venus: return SkyColor(1.0, 0.98, 0.90)
        case .mars: return SkyColor(1.0, 0.62, 0.45)
        case .jupiter: return SkyColor(1.0, 0.95, 0.85)
        case .saturn: return SkyColor(1.0, 0.90, 0.70)
        }
    }

    /// Absolute magnitude H (V at 1 AU from Sun and Earth), ignoring phase and rings.
    var absoluteMagnitude: Double {
        switch self {
        case .mercury: return -0.42
        case .venus: return -4.40
        case .mars: return -1.52
        case .jupiter: return -9.40
        case .saturn: return -8.88
        }
    }
}

/// Planet positions from JPL's "Approximate Positions of the Planets" Keplerian elements
/// (E. M. Standish), valid 1800–2050 to about an arcminute, plus light-time and precession.
public enum PlanetCalculator {
    /// a (AU), e, I, L, ϖ, Ω (degrees) at J2000 and their rates per Julian century.
    private typealias Elements = [(Double, Double)]

    private static func elements(_ body: String) -> Elements {
        switch body {
        case "mercury": return [(0.38709927, 0.00000037), (0.20563593, 0.00001906), (7.00497902, -0.00594749),
                                (252.25032350, 149_472.67411175), (77.45779628, 0.16047689), (48.33076593, -0.12534081)]
        case "venus": return [(0.72333566, 0.00000390), (0.00677672, -0.00004107), (3.39467605, -0.00078890),
                              (181.97909950, 58_517.81538729), (131.60246718, 0.00268329), (76.67984255, -0.27769418)]
        case "earth": return [(1.00000261, 0.00000562), (0.01671123, -0.00004392), (-0.00001531, -0.01294668),
                              (100.46457166, 35_999.37244981), (102.93768193, 0.32327364), (0.0, 0.0)]
        case "mars": return [(1.52371034, 0.00001847), (0.09339410, 0.00007882), (1.84969142, -0.00813131),
                             (-4.55343205, 19_140.30268499), (-23.94362959, 0.44441088), (49.55953891, -0.29257343)]
        case "jupiter": return [(5.20288700, -0.00011607), (0.04838624, -0.00013253), (1.30439695, -0.00183714),
                                (34.39644051, 3_034.74612775), (14.72847983, 0.21252668), (100.47390909, 0.20469106)]
        default: return [(9.53667594, -0.00125060), (0.05386179, -0.00050991), (2.48599187, 0.00193609),
                          (49.95424423, 1_222.49362201), (92.59887831, -0.41897216), (113.66242448, -0.28867794)]
        }
    }

    /// Heliocentric ecliptic J2000 position, AU.
    static func heliocentric(_ body: String, jd: Double) -> (x: Double, y: Double, z: Double) {
        let t = AstroMath.julianCentury(jd)
        let el = elements(body).map { $0.0 + $0.1 * t }
        let (a, e, inc, l, peri, node) = (el[0], el[1], el[2], el[3], el[4], el[5])
        let m = AstroMath.normalizeSigned(l - peri)
        let w = peri - node
        let eDeg = e * AstroMath.rad2deg
        var ea = m + eDeg * AstroMath.sind(m)
        for _ in 0..<8 { // Kepler's equation
            ea += (m - (ea - eDeg * AstroMath.sind(ea))) / (1 - e * AstroMath.cosd(ea))
        }
        let xp = a * (AstroMath.cosd(ea) - e)
        let yp = a * (1 - e * e).squareRoot() * AstroMath.sind(ea)
        let (cw, sw) = (AstroMath.cosd(w), AstroMath.sind(w))
        let (cn, sn) = (AstroMath.cosd(node), AstroMath.sind(node))
        let (ci, si) = (AstroMath.cosd(inc), AstroMath.sind(inc))
        return ((cw * cn - sw * sn * ci) * xp + (-sw * cn - cw * sn * ci) * yp,
                (cw * sn + sw * cn * ci) * xp + (-sw * sn + cw * cn * ci) * yp,
                (sw * si) * xp + (cw * si) * yp)
    }

    /// Apparent RA/Dec of date (degrees), distance from Earth and from the Sun (AU).
    public static func equatorial(_ planet: Planet, jd: Double)
        -> (rightAscension: Double, declination: Double, distance: Double, sunDistance: Double)
    {
        let earth = heliocentric("earth", jd: jd)
        var p = heliocentric(planet.rawValue, jd: jd)
        var (x, y, z) = (p.x - earth.x, p.y - earth.y, p.z - earth.z)
        // Light-time: see the planet where it was when the light left it.
        let lightDays = (x * x + y * y + z * z).squareRoot() * 0.0057755183
        p = heliocentric(planet.rawValue, jd: jd - lightDays)
        (x, y, z) = (p.x - earth.x, p.y - earth.y, p.z - earth.z)
        let d = (x * x + y * y + z * z).squareRoot()
        let eps = 23.43928 // J2000 obliquity
        let ye = y * AstroMath.cosd(eps) - z * AstroMath.sind(eps)
        let ze = y * AstroMath.sind(eps) + z * AstroMath.cosd(eps)
        let ra0 = AstroMath.normalize(AstroMath.atan2d(ye, x))
        let dec0 = AstroMath.asind(ze / d)
        let eq = Precession(fromJ2000To: jd).apply(rightAscension: ra0, declination: dec0)
        let r = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        return (eq.rightAscension, eq.declination, d, r)
    }

    public static func states(observer: Observer, at date: Date) -> [PlanetState] {
        let jd = AstroMath.julianDay(date)
        return Planet.allCases.map { planet in
            let eq = equatorial(planet, jd: jd)
            let mag = planet.absoluteMagnitude + 5 * log10(eq.sunDistance * eq.distance)
            let hz = observer.horizontal(rightAscension: eq.rightAscension, declination: eq.declination, jd: jd)
            return PlanetState(planet: planet, rightAscension: eq.rightAscension, declination: eq.declination,
                               distance: eq.distance, magnitude: mag, horizontal: hz)
        }
    }
}

/// Galactic coordinates (IAU 1958 / J2000 pole), used to draw the Milky Way.
public enum Galactic {
    static let poleRA = 192.85948, poleDec = 27.12825, northCelestialPoleLongitude = 122.93192

    /// Galactic longitude and latitude, degrees, for J2000 equatorial coordinates.
    public static func fromEquatorial(rightAscension ra: Double, declination dec: Double)
        -> (longitude: Double, latitude: Double)
    {
        let sinB = AstroMath.sind(dec) * AstroMath.sind(poleDec)
            + AstroMath.cosd(dec) * AstroMath.cosd(poleDec) * AstroMath.cosd(ra - poleRA)
        let b = AstroMath.asind(max(-1, min(1, sinB)))
        let y = AstroMath.cosd(dec) * AstroMath.sind(ra - poleRA)
        let x = AstroMath.sind(dec) * AstroMath.cosd(poleDec)
            - AstroMath.cosd(dec) * AstroMath.sind(poleDec) * AstroMath.cosd(ra - poleRA)
        let l = AstroMath.normalize(northCelestialPoleLongitude - AstroMath.atan2d(y, x))
        return (l, b)
    }

    /// Relative surface brightness of the Milky Way (0...1) at galactic coordinates:
    /// a band about 10° wide, brightest towards the centre in Sagittarius, with the
    /// Great Rift dust lane from Cygnus to Sagittarius and some mottling.
    public static func milkyWayBrightness(longitude l: Double, latitude b: Double) -> Double {
        let ls = AstroMath.normalizeSigned(l)
        let width = 7 + 5 * AstroMath.cosd(ls / 2)              // wider towards the centre
        var v = exp(-pow(b / width, 2))
        v *= 0.35 + 0.65 * pow(max(0, AstroMath.cosd(ls / 2)), 1.5) // brighter towards the centre
        // Great Rift: a dark lane just north of the plane from Sagittarius (l ≈ 0°) to Cygnus (l ≈ 80°).
        if ls > -20, ls < 95 {
            let rift = exp(-pow((b - 1.5) / 2.2, 2)) * exp(-pow((ls - 38) / 40, 2))
            v *= 1 - 0.55 * rift
        }
        // Gentle clumping along the band (star clouds), without striping across it.
        let mottle = 0.8 + 0.2 * sin(l * 0.09 + 1.3) * cos(b * 0.25) + 0.1 * sin(l * 0.31 + 0.4)
        return max(0, min(1, v * mottle))
    }
}
