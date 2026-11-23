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

final class AtmosphereTests: XCTestCase {
    private func sky(sunAltitude: Double, turbidity: Double = 2.5) -> PreethamSky {
        PreethamSky(turbidity: turbidity, sunZenith: (90 - sunAltitude) * AstroMath.deg2rad)
    }

    /// Preetham zenith luminance for T = 2.5 with the Sun 60° up is 8.19 kcd/m² (eq. A.2).
    func testZenithLuminanceIsPlausible() {
        XCTAssertEqual(sky(sunAltitude: 60).zenithLuminance, 8.19, accuracy: 0.01)
        XCTAssertLessThan(sky(sunAltitude: 10).zenithLuminance, sky(sunAltitude: 60).zenithLuminance)
    }

    func testClearMiddaySkyIsBlueAtZenith() {
        let model = sky(sunAltitude: 55)
        let c = model.displayColor(theta: 0, gamma: 35 * AstroMath.deg2rad)
        XCTAssertGreaterThan(c.b, c.r + 0.15)
        XCTAssertGreaterThan(c.b, c.g)
    }

    func testSkyIsBrighterNearTheSun() {
        let model = sky(sunAltitude: 30)
        let near = model.displayColor(theta: 60 * AstroMath.deg2rad, gamma: 5 * AstroMath.deg2rad)
        let away = model.displayColor(theta: 60 * AstroMath.deg2rad, gamma: 150 * AstroMath.deg2rad)
        XCTAssertGreaterThan(near.r + near.g + near.b, away.r + away.g + away.b)
    }

    func testHazeRaisesTurbidity() {
        XCTAssertLessThan(PreethamSky.turbidity(visibility: 50_000), 3)
        XCTAssertGreaterThan(PreethamSky.turbidity(visibility: 4_000), 6)
    }

    func testProjectionRoundTrip() {
        let p = SkyProjection(width: 1800, height: 1169, facingAzimuth: 180)
        let h = HorizontalCoordinates(altitude: 23.5, azimuth: 141)
        let pt = try! XCTUnwrap(p.point(h))
        let back = p.direction(x: pt.x, y: pt.y)
        XCTAssertEqual(back.altitude, 23.5, accuracy: 1e-9)
        XCTAssertEqual(back.azimuth, 141, accuracy: 1e-9)
    }

    func testRendererFillsBuffer() {
        let builder = SkySceneBuilder(observer: Observer(latitude: 51.5, longitude: -0.13), catalog: nil)
        let scene = builder.scene(at: Date(timeIntervalSince1970: 1_782_043_200), weather: .clear) // 21 Jun 2026 12:00 UTC
        let p = SkyProjection(width: 1800, height: 1169, facingAzimuth: 180)
        let px = SkyGradientRenderer().render(scene: scene, projection: p, width: 32, height: 20)
        XCTAssertEqual(px.count, 32 * 20 * 4)
        // Top-centre pixel is a daytime blue.
        let o = (0 * 32 + 16) * 4
        XCTAssertGreaterThan(Int(px[o + 2]), Int(px[o]))
        XCTAssertGreaterThan(Int(px[o + 2]), 150)
    }
}

final class FieldOfViewTests: XCTestCase {
    private func utc(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: y, month: mo, day: d, hour: 12))!
    }
    private let london = Observer(latitude: 51.5074, longitude: -0.1278)
    private let utcZone = TimeZone(identifier: "UTC")!

    /// London midsummer: sunrise at azimuth 48.9°, 131° from south, so the view spans about 286°.
    func testWidensInSummerToShowSunriseAndSunset() {
        let fov = SkyProjection.seasonalFieldOfView(observer: london, date: utc(2026, 6, 21), timeZone: utcZone)
        XCTAssertEqual(fov, 286.2, accuracy: 1)
        let calc = SolarCalculator(observer: london)
        let day = calc.day(containing: utc(2026, 6, 21), timeZone: utcZone)
        let p = SkyProjection(width: 1800, height: 1169, facingAzimuth: 180, horizontalFOV: fov)
        for event in [day.sunrise!, day.sunset!] {
            let pt = try! XCTUnwrap(p.point(calc.position(at: event).horizontal))
            XCTAssertGreaterThan(pt.x, 0)
            XCTAssertLessThan(pt.x, 1800)
        }
    }

    func testStaysNarrowInWinter() {
        XCTAssertEqual(SkyProjection.seasonalFieldOfView(observer: london, date: utc(2026, 12, 21), timeZone: utcZone), 140)
    }

    func testPolarDayUsesMaximum() {
        let tromso = Observer(latitude: 69.65, longitude: 18.96)
        XCTAssertEqual(SkyProjection.seasonalFieldOfView(observer: tromso, date: utc(2026, 6, 21), timeZone: utcZone), 300)
    }
}

final class NightSkyTests: XCTestCase {
    /// Meeus example 47.a: 1992 Apr 12.0 TD, apparent RA 134.688470°, Dec 13.768368°, distance 368409.7 km.
    func testMoonPositionMeeus47a() {
        let m = MoonCalculator.apparentEquatorial(jd: 2_448_724.5)
        XCTAssertEqual(m.rightAscension, 134.688470, accuracy: 0.01)
        XCTAssertEqual(m.declination, 13.768368, accuracy: 0.01)
        XCTAssertEqual(m.distance, 368_409.7, accuracy: 50)
    }

    /// Meeus example 48.a: same instant, illuminated fraction 0.6786, phase angle 69.0756°.
    func testMoonPhaseMeeus48a() {
        let s = MoonCalculator.state(observer: Observer(latitude: 0, longitude: 0),
                                     at: AstroMath.date(fromJulianDay: 2_448_724.5))
        XCTAssertEqual(s.illuminatedFraction, 0.6786, accuracy: 0.002)
        XCTAssertEqual(s.phaseAngle, 69.0756, accuracy: 0.1)
        XCTAssertTrue(s.isWaxing)
    }

    /// Meeus example 33.a: Venus on 1992 Dec 20.0 TD at RA 21h 04m 41.454s, Dec −18° 53′ 16.84″.
    func testVenusMeeus33a() {
        let v = PlanetCalculator.equatorial(.venus, jd: 2_448_976.5)
        XCTAssertEqual(v.rightAscension, 316.172725, accuracy: 0.02)
        XCTAssertEqual(v.declination, -18.888011, accuracy: 0.02)
        XCTAssertEqual(v.distance, 0.911, accuracy: 0.002)
    }

    func testGalacticCentre() {
        let g = Galactic.fromEquatorial(rightAscension: 266.40510, declination: -28.936175) // Sgr A*
        XCTAssertEqual(AstroMath.normalizeSigned(g.longitude), 0, accuracy: 0.01)
        XCTAssertEqual(g.latitude, 0, accuracy: 0.01)
        XCTAssertGreaterThan(Galactic.milkyWayBrightness(longitude: 0, latitude: 0),
                             Galactic.milkyWayBrightness(longitude: 180, latitude: 0))
        XCTAssertLessThan(Galactic.milkyWayBrightness(longitude: 0, latitude: 40), 0.05)
    }
}

final class MoonImageTests: XCTestCase {
    /// A plain grey surface map is enough to check lighting and transparency.
    private let renderer = MoonImageRenderer(
        surface: RGBAImage(width: 8, height: 4, pixels: [UInt8](repeating: 180, count: 8 * 4 * 4)))

    private func pixel(_ img: RGBAImage, _ x: Int, _ y: Int) -> (r: Int, a: Int) {
        let o = (y * img.width + x) * 4
        return (Int(img.pixels[o]), Int(img.pixels[o + 3]))
    }

    func testCornersAreTransparent() {
        let img = renderer.render(size: 64, phaseAngle: 0, sunAngle: 0, northAngle: -.pi / 2)
        XCTAssertEqual(pixel(img, 0, 0).a, 0)
        XCTAssertEqual(pixel(img, 32, 32).a, 255)
    }

    func testFirstQuarterIsLitTowardsTheSun() {
        // Sun to the right of the Moon on screen.
        let img = renderer.render(size: 64, phaseAngle: 90, sunAngle: 0, northAngle: -.pi / 2)
        XCTAssertGreaterThan(pixel(img, 52, 32).r, 100)  // right half lit
        XCTAssertLessThan(pixel(img, 12, 32).r, 25)      // left half in earthshine
    }

    func testFullMoonIsEvenlyBright() {
        // Lommel–Seeliger: no limb darkening at full Moon.
        let img = renderer.render(size: 64, phaseAngle: 0, sunAngle: 0, northAngle: -.pi / 2)
        XCTAssertEqual(Double(pixel(img, 32, 32).r), Double(pixel(img, 58, 32).r), accuracy: 4)
    }

    func testDarkSideIsTransparentByDay() {
        let img = renderer.render(size: 64, phaseAngle: 90, sunAngle: 0, northAngle: -.pi / 2,
                                  earthshine: 0, darkSideOpacity: 0)
        XCTAssertLessThan(pixel(img, 12, 32).a, 10)
        XCTAssertEqual(pixel(img, 52, 32).a, 255)
    }
}
