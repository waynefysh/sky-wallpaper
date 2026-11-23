import XCTest
@testable import SkyCore

/// Reference values come from Meeus, *Astronomical Algorithms* (2nd ed.) worked examples,
/// and from published sunrise/sunset tables (timeanddate.com) for 2026.
final class SolarTests: XCTestCase {
    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        let c = DateComponents(timeZone: TimeZone(identifier: "UTC"),
                               year: y, month: mo, day: d, hour: h, minute: mi)
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func localTime(_ date: Date?, _ tz: String) -> String {
        guard let date else { return "none" }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: tz)
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Meeus example 25.a: 1992 Oct 13.0 TD, apparent RA 198.38083°, Dec -7.78507°.
    func testSunCoordinatesMeeus25a() {
        let s = SolarCalculator.solarCoordinates(jd: 2_448_908.5)
        XCTAssertEqual(s.rightAscension, 198.38083, accuracy: 0.001)
        XCTAssertEqual(s.declination, -7.78507, accuracy: 0.001)
    }

    /// Meeus example 28.a: equation of time on 1992 Oct 13.0 TD is 13m 42.6s.
    func testEquationOfTimeMeeus28a() {
        XCTAssertEqual(SolarCalculator.solarCoordinates(jd: 2_448_908.5).equationOfTime, 13.71, accuracy: 0.02)
    }

    /// Meeus example 12.a: GMST at 1987 Apr 10 0h UT is 13h 10m 46.3668s.
    func testSiderealTimeMeeus12a() {
        XCTAssertEqual(AstroMath.greenwichMeanSiderealTime(jd: 2_446_895.5), 197.693195, accuracy: 0.00001)
    }

    func testLondonSummerSolstice() {
        let calc = SolarCalculator(observer: Observer(latitude: 51.5074, longitude: -0.1278))
        let day = calc.day(containing: utc(2026, 6, 21, 12), timeZone: TimeZone(identifier: "Europe/London")!)
        XCTAssertEqual(localTime(day.sunrise, "Europe/London"), "04:43")
        XCTAssertEqual(localTime(day.sunset, "Europe/London"), "21:21")
        XCTAssertEqual(day.daylight / 3600, 16.64, accuracy: 0.05)
    }

    func testLondonWinterSolstice() {
        let calc = SolarCalculator(observer: Observer(latitude: 51.5074, longitude: -0.1278))
        let day = calc.day(containing: utc(2026, 12, 21, 12), timeZone: TimeZone(identifier: "Europe/London")!)
        XCTAssertEqual(localTime(day.sunrise, "Europe/London"), "08:03") // 08:03:44
        XCTAssertEqual(localTime(day.sunset, "Europe/London"), "15:53")
    }

    func testSydneySummer() {
        let calc = SolarCalculator(observer: Observer(latitude: -33.8688, longitude: 151.2093))
        let day = calc.day(containing: utc(2026, 12, 21, 2), timeZone: TimeZone(identifier: "Australia/Sydney")!)
        XCTAssertEqual(localTime(day.sunrise, "Australia/Sydney"), "05:40") // 05:40:38
        XCTAssertEqual(localTime(day.sunset, "Australia/Sydney"), "20:05")
    }

    func testPolarDayAndNight() {
        let calc = SolarCalculator(observer: Observer(latitude: 69.65, longitude: 18.96)) // Tromsø
        let oslo = TimeZone(identifier: "Europe/Oslo")!
        let winter = calc.day(containing: utc(2026, 12, 21, 12), timeZone: oslo)
        XCTAssertTrue(winter.isPolarNight)
        XCTAssertNil(winter.sunrise)
        let summer = calc.day(containing: utc(2026, 6, 21, 12), timeZone: oslo)
        XCTAssertTrue(summer.isPolarDay)
        XCTAssertEqual(summer.daylight, 86_400)
    }

    func testNoonPositionLondon() {
        let calc = SolarCalculator(observer: Observer(latitude: 51.5074, longitude: -0.1278))
        let p = calc.position(at: utc(2026, 6, 21, 12)).horizontal
        XCTAssertEqual(p.altitude, 61.94, accuracy: 0.05)
        XCTAssertEqual(p.azimuth, 178.86, accuracy: 0.1) // just east of due south before solar noon
    }
}

final class StarTests: XCTestCase {
    /// Meeus example 21.b: θ Persei from J2000 (with proper motion applied) to 2028 Nov 13.19 TD
    /// gives RA 2h 46m 11.331s (41.547214°), Dec +49° 20′ 54.54″ (49.348483°).
    func testPrecessionMeeus21b() {
        let jd = 2_462_088.69
        let years = (jd - 2_451_545.0) / 365.25
        let ra0 = (2 + 44 / 60.0 + 11.986 / 3600) * 15 + 0.03425 * 15 * years / 3600
        let dec0 = 49 + 13 / 60.0 + 42.48 / 3600 - 0.0895 * years / 3600
        let p = Precession(fromJ2000To: jd).apply(rightAscension: ra0, declination: dec0)
        XCTAssertEqual(p.rightAscension, 41.547214, accuracy: 0.00005)
        XCTAssertEqual(p.declination, 49.348483, accuracy: 0.00005)
    }

    func testPolarisAltitudeMatchesLatitude() throws {
        let catalog = try StarCatalog(csv: "hr,ra_deg,dec_deg,vmag,kelvin,name\n424,37.95454,89.26411,2.02,6000,Polaris\n")
        let london = Observer(latitude: 51.5074, longitude: -0.1278)
        let stars = catalog.visibleStars(observer: london, at: Date(timeIntervalSince1970: 1_800_000_000))
        let polaris = try XCTUnwrap(stars.first)
        XCTAssertEqual(polaris.horizontal.altitude, 51.5, accuracy: 1.0) // Polaris is 0.7° from the pole
        XCTAssertEqual(AstroMath.normalizeSigned(polaris.horizontal.azimuth), 0, accuracy: 1.5)
    }

    func testBundledCatalogLoads() throws {
        let catalog = try StarCatalog.bundled()
        XCTAssertGreaterThan(catalog.stars.count, 9_000)
        XCTAssertEqual(catalog.stars.first?.name, "Sirius") // sorted brightest first
    }
}

final class WeatherTests: XCTestCase {
    func testParsesOpenMeteoCurrent() throws {
        let json = """
        {"current":{"time":1795379700,"temperature_2m":7.4,"precipitation":1.2,"rain":1.2,"showers":0,
        "snowfall":0,"weather_code":63,"cloud_cover":100,"cloud_cover_low":88,"cloud_cover_mid":40,
        "cloud_cover_high":5,"wind_speed_10m":6.1,"wind_direction_10m":225,"visibility":8000}}
        """
        let w = try OpenMeteoProvider.parse(Data(json.utf8))
        XCTAssertEqual(w.cloudLow, 0.88, accuracy: 1e-9)
        XCTAssertEqual(w.precipitation, .rain)
        XCTAssertEqual(w.precipitationRate, 1.2)
        XCTAssertFalse(w.isThunderstorm)
        XCTAssertEqual(w.visibility, 8000)
    }

    func testWeatherCodeMapping() {
        XCTAssertEqual(OpenMeteoProvider.precipitationKind(weatherCode: 0), .none)
        XCTAssertEqual(OpenMeteoProvider.precipitationKind(weatherCode: 53), .drizzle)
        XCTAssertEqual(OpenMeteoProvider.precipitationKind(weatherCode: 73), .snow)
        XCTAssertEqual(OpenMeteoProvider.precipitationKind(weatherCode: 99), .hail)
    }
}
