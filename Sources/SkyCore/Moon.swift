import Foundation

/// The Moon's place and phase at one instant.
public struct MoonState: Sendable {
    /// Apparent geocentric right ascension and declination, degrees.
    public var rightAscension: Double
    public var declination: Double
    /// Distance from the Earth's centre, km.
    public var distance: Double
    /// Topocentric altitude (with parallax and refraction) and azimuth.
    public var horizontal: HorizontalCoordinates
    /// Fraction of the disc that is lit, 0 (new) ... 1 (full).
    public var illuminatedFraction: Double
    /// Phase angle Sun–Moon–Earth, degrees (0 = full, 180 = new).
    public var phaseAngle: Double
    /// True while the Moon is getting fuller (new to full).
    public var isWaxing: Bool
}

/// Moon position from Meeus, *Astronomical Algorithms* ch. 47 (ELP-2000/82 truncated to its
/// largest terms, good to about 0.01°), and phase from ch. 48.
public enum MoonCalculator {
    // D, M, M', F, Σl coefficient (1e-6°), Σr coefficient (1e-3 km). Meeus table 47.A.
    private static let lonDist: [(Double, Double, Double, Double, Double, Double)] = [
        (0, 0, 1, 0, 6_288_774, -20_905_355), (2, 0, -1, 0, 1_274_027, -3_699_111),
        (2, 0, 0, 0, 658_314, -2_955_968), (0, 0, 2, 0, 213_618, -569_925),
        (0, 1, 0, 0, -185_116, 48_888), (0, 0, 0, 2, -114_332, -3_149),
        (2, 0, -2, 0, 58_793, 246_158), (2, -1, -1, 0, 57_066, -152_138),
        (2, 0, 1, 0, 53_322, -170_733), (2, -1, 0, 0, 45_758, -204_586),
        (0, 1, -1, 0, -40_923, -129_620), (1, 0, 0, 0, -34_720, 108_743),
        (0, 1, 1, 0, -30_383, 104_755), (2, 0, 0, -2, 15_327, 10_321),
        (0, 0, 1, 2, -12_528, 0), (0, 0, 1, -2, 10_980, 79_661),
        (4, 0, -1, 0, 10_675, -34_782), (0, 0, 3, 0, 10_034, -23_210),
        (4, 0, -2, 0, 8_548, -21_636), (2, 1, -1, 0, -7_888, 24_208),
        (2, 1, 0, 0, -6_766, 30_824), (1, 0, -1, 0, -5_163, -8_379),
        (1, 1, 0, 0, 4_987, -16_675), (2, -1, 1, 0, 4_036, -12_831),
        (2, 0, 2, 0, 3_994, -10_445), (4, 0, 0, 0, 3_861, -11_650),
        (2, 0, -3, 0, 3_665, 14_403), (0, 1, -2, 0, -2_689, -7_003),
        (2, 0, -1, 2, -2_602, 0), (2, -1, -2, 0, 2_390, 10_056),
        (1, 0, 1, 0, -2_348, 6_322), (2, -2, 0, 0, 2_236, -9_884),
        (0, 1, 2, 0, -2_120, 5_751), (0, 2, 0, 0, -2_069, 0),
    ]
    // D, M, M', F, Σb coefficient (1e-6°). Meeus table 47.B.
    private static let lat: [(Double, Double, Double, Double, Double)] = [
        (0, 0, 0, 1, 5_128_122), (0, 0, 1, 1, 280_602), (0, 0, 1, -1, 277_693),
        (2, 0, 0, -1, 173_237), (2, 0, -1, 1, 55_413), (2, 0, -1, -1, 46_271),
        (2, 0, 0, 1, 32_573), (0, 0, 2, 1, 17_198), (2, 0, 1, -1, 9_266),
        (0, 0, 2, -1, 8_822), (2, -1, 0, -1, 8_216), (2, 0, -2, -1, 4_324),
        (2, 0, 1, 1, 4_200), (2, 1, 0, -1, -3_359), (2, -1, -1, 1, 2_463),
        (2, -1, 0, 1, 2_211), (2, -1, -1, -1, 2_065), (0, 1, -1, -1, -1_870),
        (4, 0, -1, -1, 1_828), (0, 1, 0, 1, -1_794),
    ]

    /// Geocentric ecliptic longitude/latitude of date (no nutation), degrees, and distance in km.
    public static func eclipticPosition(jd: Double) -> (longitude: Double, latitude: Double, distance: Double) {
        let t = AstroMath.julianCentury(jd)
        let t2 = t * t, t3 = t2 * t, t4 = t3 * t
        let lp = AstroMath.normalize(218.3164477 + 481_267.88123421 * t - 0.0015786 * t2 + t3 / 538_841 - t4 / 65_194_000)
        let d = AstroMath.normalize(297.8501921 + 445_267.1114034 * t - 0.0018819 * t2 + t3 / 545_868 - t4 / 113_065_000)
        let m = AstroMath.normalize(357.5291092 + 35_999.0502909 * t - 0.0001536 * t2 + t3 / 24_490_000)
        let mp = AstroMath.normalize(134.9633964 + 477_198.8675055 * t + 0.0087414 * t2 + t3 / 69_699 - t4 / 14_712_000)
        let f = AstroMath.normalize(93.2720950 + 483_202.0175233 * t - 0.0036539 * t2 - t3 / 3_526_000 + t4 / 863_310_000)
        let a1 = 119.75 + 131.849 * t, a2 = 53.09 + 479_264.290 * t, a3 = 313.45 + 481_266.484 * t
        let e = 1 - 0.002516 * t - 0.0000074 * t2

        var sl = 0.0, sr = 0.0, sb = 0.0
        for (cd, cm, cmp, cf, l, r) in lonDist {
            let ef = pow(e, abs(cm))
            let arg = cd * d + cm * m + cmp * mp + cf * f
            sl += l * ef * AstroMath.sind(arg)
            sr += r * ef * AstroMath.cosd(arg)
        }
        for (cd, cm, cmp, cf, b) in lat {
            sb += b * pow(e, abs(cm)) * AstroMath.sind(cd * d + cm * m + cmp * mp + cf * f)
        }
        sl += 3958 * AstroMath.sind(a1) + 1962 * AstroMath.sind(lp - f) + 318 * AstroMath.sind(a2)
        sb += -2235 * AstroMath.sind(lp) + 382 * AstroMath.sind(a3) + 175 * AstroMath.sind(a1 - f)
            + 175 * AstroMath.sind(a1 + f) + 127 * AstroMath.sind(lp - mp) - 115 * AstroMath.sind(lp + mp)
        return (AstroMath.normalize(lp + sl / 1e6), sb / 1e6, 385_000.56 + sr / 1000)
    }

    /// Nutation in longitude and true obliquity of the ecliptic, degrees (Meeus ch. 22, low precision).
    public static func nutationAndObliquity(jd: Double) -> (nutationInLongitude: Double, obliquity: Double) {
        let t = AstroMath.julianCentury(jd)
        let om = 125.04452 - 1934.136261 * t
        let ls = 280.4665 + 36_000.7698 * t, lm = 218.3165 + 481_267.8813 * t
        let dpsi = (-17.20 * AstroMath.sind(om) - 1.32 * AstroMath.sind(2 * ls)
            - 0.23 * AstroMath.sind(2 * lm) + 0.21 * AstroMath.sind(2 * om)) / 3600
        let deps = (9.20 * AstroMath.cosd(om) + 0.57 * AstroMath.cosd(2 * ls)
            + 0.10 * AstroMath.cosd(2 * lm) - 0.09 * AstroMath.cosd(2 * om)) / 3600
        let eps0 = 23 + 26 / 60.0 + 21.448 / 3600 - (46.8150 * t + 0.00059 * t * t - 0.001813 * t * t * t) / 3600
        return (dpsi, eps0 + deps)
    }

    /// Apparent geocentric RA/Dec, degrees, and distance in km.
    public static func apparentEquatorial(jd: Double) -> (rightAscension: Double, declination: Double, distance: Double) {
        let p = eclipticPosition(jd: jd)
        let n = nutationAndObliquity(jd: jd)
        let lam = p.longitude + n.nutationInLongitude, beta = p.latitude, eps = n.obliquity
        let ra = AstroMath.normalize(AstroMath.atan2d(
            AstroMath.sind(lam) * AstroMath.cosd(eps) - AstroMath.tand(beta) * AstroMath.sind(eps),
            AstroMath.cosd(lam)))
        let dec = AstroMath.asind(AstroMath.sind(beta) * AstroMath.cosd(eps)
            + AstroMath.cosd(beta) * AstroMath.sind(eps) * AstroMath.sind(lam))
        return (ra, dec, p.distance)
    }

    public static func state(observer: Observer, at date: Date) -> MoonState {
        let jd = AstroMath.julianDay(date)
        let eq = apparentEquatorial(jd: jd)
        // Geometric altitude, then topocentric parallax (up to ~1°), then refraction.
        var hz = observer.horizontal(rightAscension: eq.rightAscension, declination: eq.declination,
                                     jd: jd, applyRefraction: false)
        let parallax = AstroMath.asind(6378.14 / eq.distance)
        hz.altitude -= parallax * AstroMath.cosd(hz.altitude)
        hz.altitude += AstroMath.refraction(trueAltitude: hz.altitude)

        // Phase (Meeus ch. 48) from the Sun's apparent position.
        let sun = SolarCalculator.solarCoordinates(jd: jd)
        let cosPsi = AstroMath.sind(sun.declination) * AstroMath.sind(eq.declination)
            + AstroMath.cosd(sun.declination) * AstroMath.cosd(eq.declination)
            * AstroMath.cosd(sun.rightAscension - eq.rightAscension)
        let psi = AstroMath.acosd(max(-1, min(1, cosPsi)))
        let sunDistanceKm = 149_597_870.7 // 1 AU; the ~1.7% annual variation is negligible here
        let i = AstroMath.atan2d(sunDistanceKm * AstroMath.sind(psi), eq.distance - sunDistanceKm * AstroMath.cosd(psi))
        let k = (1 + AstroMath.cosd(i)) / 2
        // Waxing when the Moon is east of the Sun (0...180° ahead in RA).
        let waxing = AstroMath.normalize(eq.rightAscension - sun.rightAscension) < 180

        return MoonState(rightAscension: eq.rightAscension, declination: eq.declination, distance: eq.distance,
                         horizontal: hz, illuminatedFraction: k, phaseAngle: i, isWaxing: waxing)
    }
}
