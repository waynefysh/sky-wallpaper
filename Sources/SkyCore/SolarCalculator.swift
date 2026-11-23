import Foundation

/// The Sun's place in the sky at one instant.
public struct SolarPosition: Equatable, Sendable {
    /// Apparent right ascension, degrees.
    public var rightAscension: Double
    /// Apparent declination, degrees.
    public var declination: Double
    /// Equation of time in minutes (apparent minus mean solar time).
    public var equationOfTime: Double
    /// Local hour angle, degrees in [-180, 180). Negative before solar noon.
    public var hourAngle: Double
    /// Altitude (with refraction) and azimuth for the observer.
    public var horizontal: HorizontalCoordinates
}

/// Rise, set and twilight times for one local calendar day.
public struct SolarDay: Equatable, Sendable {
    public var solarNoon: Date
    public var sunrise: Date?
    public var sunset: Date?
    public var civilDawn: Date?
    public var civilDusk: Date?
    public var nauticalDawn: Date?
    public var nauticalDusk: Date?
    public var astronomicalDawn: Date?
    public var astronomicalDusk: Date?
    /// Sun never sets (midnight sun) on this day.
    public var isPolarDay: Bool
    /// Sun never rises (polar night) on this day.
    public var isPolarNight: Bool

    /// Length of daylight, sunrise to sunset. 24 h on a polar day, 0 on a polar night.
    public var daylight: TimeInterval {
        if isPolarDay { return 86_400 }
        guard let r = sunrise, let s = sunset else { return 0 }
        return s.timeIntervalSince(r)
    }
}

/// Altitudes that define rise/set and twilights, in degrees of the Sun's centre.
public enum SolarAltitude {
    /// Upper limb on the horizon, including 34′ refraction and 16′ semi-diameter.
    public static let sunriseSunset = -0.833
    public static let civil = -6.0
    public static let nautical = -12.0
    public static let astronomical = -18.0
}

/// NOAA solar calculator (based on Meeus, *Astronomical Algorithms*, ch. 25),
/// accurate to about 0.01° in position and about a minute in rise/set times for
/// dates within a few centuries of 2000.
public struct SolarCalculator: Sendable {
    public var observer: Observer

    public init(observer: Observer) {
        self.observer = observer
    }

    // MARK: - Position

    public func position(at date: Date) -> SolarPosition {
        let jd = AstroMath.julianDay(date)
        let s = Self.solarCoordinates(jd: jd)
        let ha = hourAngle(at: date, equationOfTime: s.equationOfTime)
        let hz = Observer.horizontal(hourAngle: ha, declination: s.declination,
                                     latitude: observer.latitude, applyRefraction: true)
        return SolarPosition(rightAscension: s.rightAscension, declination: s.declination,
                             equationOfTime: s.equationOfTime, hourAngle: ha, horizontal: hz)
    }

    /// Low-level apparent solar coordinates for a Julian Day.
    public static func solarCoordinates(jd: Double)
        -> (rightAscension: Double, declination: Double, equationOfTime: Double)
    {
        let t = AstroMath.julianCentury(jd)
        let l0 = AstroMath.normalize(280.46646 + t * (36_000.76983 + t * 0.0003032))
        let m = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = AstroMath.sind(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + AstroMath.sind(2 * m) * (0.019993 - 0.000101 * t)
            + AstroMath.sind(3 * m) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1_934.136 * t
        let appLong = trueLong - 0.00569 - 0.00478 * AstroMath.sind(omega)
        let meanObliq = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliq = meanObliq + 0.00256 * AstroMath.cosd(omega)

        let dec = AstroMath.asind(AstroMath.sind(obliq) * AstroMath.sind(appLong))
        let ra = AstroMath.normalize(
            AstroMath.atan2d(AstroMath.cosd(obliq) * AstroMath.sind(appLong), AstroMath.cosd(appLong))
        )

        let y = pow(AstroMath.tand(obliq / 2), 2)
        let eqRad = y * AstroMath.sind(2 * l0)
            - 2 * e * AstroMath.sind(m)
            + 4 * e * y * AstroMath.sind(m) * AstroMath.cosd(2 * l0)
            - 0.5 * y * y * AstroMath.sind(4 * l0)
            - 1.25 * e * e * AstroMath.sind(2 * m)
        let eqTime = 4 * eqRad * AstroMath.rad2deg // minutes

        return (ra, dec, eqTime)
    }

    /// Local hour angle of the Sun, from true solar time.
    private func hourAngle(at date: Date, equationOfTime eqt: Double) -> Double {
        let utcMinutes = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 60
        let trueSolarMinutes = utcMinutes + eqt + 4 * observer.longitude
        return AstroMath.normalizeSigned(trueSolarMinutes / 4 - 180)
    }

    // MARK: - Rise, set, twilight

    /// Events for the calendar day containing `date` in `timeZone`.
    public func day(containing date: Date, timeZone: TimeZone = .current) -> SolarDay {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let midnight = cal.startOfDay(for: date)
        let noon = solarNoon(near: midnight.addingTimeInterval(12 * 3600))

        let rise = { (alt: Double) in self.crossing(altitude: alt, from: noon, rising: true) }
        let set = { (alt: Double) in self.crossing(altitude: alt, from: noon, rising: false) }

        let noonAlt = position(at: noon).horizontal.altitude
        let sunrise = rise(SolarAltitude.sunriseSunset)
        let sunset = set(SolarAltitude.sunriseSunset)

        return SolarDay(
            solarNoon: noon,
            sunrise: sunrise,
            sunset: sunset,
            civilDawn: rise(SolarAltitude.civil),
            civilDusk: set(SolarAltitude.civil),
            nauticalDawn: rise(SolarAltitude.nautical),
            nauticalDusk: set(SolarAltitude.nautical),
            astronomicalDawn: rise(SolarAltitude.astronomical),
            astronomicalDusk: set(SolarAltitude.astronomical),
            isPolarDay: sunrise == nil && noonAlt > 0,
            isPolarNight: sunrise == nil && noonAlt <= 0
        )
    }

    /// Time of upper transit (solar noon) closest to `guess`.
    public func solarNoon(near guess: Date) -> Date {
        var t = guess
        for _ in 0..<3 {
            let s = Self.solarCoordinates(jd: AstroMath.julianDay(t))
            let ha = hourAngle(at: t, equationOfTime: s.equationOfTime)
            t = t.addingTimeInterval(-ha * 240) // 1° of hour angle = 4 min = 240 s
        }
        return t
    }

    /// Time the Sun's centre crosses `altitude` before (rising) or after (setting) `noon`.
    /// Returns nil if it does not reach that altitude on this day.
    public func crossing(altitude h0: Double, from noon: Date, rising: Bool) -> Date? {
        var t = noon
        for _ in 0..<4 {
            let s = Self.solarCoordinates(jd: AstroMath.julianDay(t))
            let cosH = (AstroMath.sind(h0) - AstroMath.sind(observer.latitude) * AstroMath.sind(s.declination))
                / (AstroMath.cosd(observer.latitude) * AstroMath.cosd(s.declination))
            guard cosH >= -1, cosH <= 1 else { return nil }
            let target = AstroMath.acosd(cosH) * (rising ? -1 : 1)
            let ha = hourAngle(at: t, equationOfTime: s.equationOfTime)
            // Hour angle is near 0 at noon and near `target` once converged,
            // so the step always stays on the correct side of noon.
            t = t.addingTimeInterval((target - ha) * 240)
        }
        return t
    }
}
