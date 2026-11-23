import XCTest
@testable import SkyCore

final class CloudTests: XCTestCase {
    /// The share of a deck that is cloudy should follow the reported cover.
    func testCoverageFollowsCloudCover() {
        let noise = GradientNoise(seed: 7)
        for cover in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let layer = CloudLayer(kind: .cumulus, cover: cover, height: 1.4, featureSize: 2.2, offset: (0, 0))
            var cloudy = 0, total = 0
            for i in 0..<120 {
                for j in 0..<120 {
                    total += 1
                    if layer.density(noise, east: Double(i) * 1.7, north: Double(j) * 1.7) > 0.5 { cloudy += 1 }
                }
            }
            XCTAssertEqual(Double(cloudy) / Double(total), cover, accuracy: 0.12, "cover \(cover)")
        }
    }

    func testRayMeetsDeckOverheadAndAtHorizon() {
        XCTAssertEqual(CloudRenderer.groundDistance(altitude: 90, height: 2), 0, accuracy: 1e-6)
        // At the horizon a deck 1.4 km up is about sqrt(2Rh) ≈ 134 km away.
        XCTAssertEqual(CloudRenderer.groundDistance(altitude: 0, height: 1.4), (2 * 6371 * 1.4).squareRoot(), accuracy: 1)
        XCTAssertEqual(CloudRenderer.groundDistance(altitude: 30, height: 1), 1 / tan(30 * Double.pi / 180), accuracy: 0.01)
    }

    func testLowSunIsRedder() {
        let high = CloudRenderer.sunlightColor(altitude: 50)
        let low = CloudRenderer.sunlightColor(altitude: 1)
        XCTAssertGreaterThan(high.b / high.r, 0.8)
        XCTAssertLessThan(low.b / low.r, 0.3)
    }

    private func scene(sunAltitudeNear target: Double, weather: WeatherConditions) -> SkyScene {
        // Step through 21 June 2026 in London until the Sun is at the wanted altitude.
        let builder = SkySceneBuilder(observer: Observer(latitude: 51.5, longitude: -0.13), catalog: nil)
        var date = Date(timeIntervalSince1970: 1_782_043_200) // 12:00 UTC
        var s = builder.scene(at: date, weather: weather, includeStars: false)
        while s.sun.horizontal.altitude > target {
            date.addTimeInterval(60)
            s = builder.scene(at: date, weather: weather, includeStars: false)
        }
        return s
    }

    func testClearSkyHasNoClouds() {
        let s = scene(sunAltitudeNear: 40, weather: .clear)
        let pr = SkyProjection(width: 1280, height: 800, facingAzimuth: 180)
        let img = CloudRenderer().render(scene: s, projection: pr, width: 64, height: 40, time: 0)
        XCTAssertEqual(img.pixels.enumerated().filter { $0.offset % 4 == 3 }.map(\.element).max(), 0)
    }

    func testOvercastCoversTheSkyAndFogHidesTheHorizon() {
        let s = scene(sunAltitudeNear: 30, weather: .sample(.overcast))
        let pr = SkyProjection(width: 1280, height: 800, facingAzimuth: 180)
        let img = CloudRenderer().render(scene: s, projection: pr, width: 64, height: 40, time: 0)
        let alphas = stride(from: 3, to: img.pixels.count, by: 4).map { Double(img.pixels[$0]) / 255 }
        XCTAssertGreaterThan(alphas.reduce(0, +) / Double(alphas.count), 0.8)

        let foggy = scene(sunAltitudeNear: 10, weather: .sample(.fog))
        let f = CloudRenderer().render(scene: foggy, projection: pr, width: 64, height: 40, time: 0)
        let horizonRow = Int(40 * 66.0 / 70) // altitude ≈ 0°
        XCTAssertGreaterThan(f.pixels[(horizonRow * 64 + 32) * 4 + 3], 230)
    }

    /// High cloud stays sunlit for a while after sunset at the ground; low cloud goes grey.
    func testHighCloudCatchesTheSunAfterSunset() {
        var w = WeatherConditions.clear
        (w.cloudHigh, w.cloudLow) = (0.95, 0)
        let s = scene(sunAltitudeNear: -2, weather: w)
        var low = w
        (low.cloudHigh, low.cloudLow) = (0, 0.95)
        let s2 = SkySceneBuilder(observer: s.observer, catalog: nil).scene(at: s.date, weather: low, includeStars: false)
        let pr = SkyProjection(width: 1280, height: 800, facingAzimuth: s.sun.horizontal.azimuth)
        func redness(_ sc: SkyScene) -> Double {
            let img = CloudRenderer().render(scene: sc, projection: pr, width: 32, height: 20, time: 0)
            let o = (6 * 32 + 16) * 4 // well above the horizon, towards the Sun
            return Double(img.pixels[o]) - Double(img.pixels[o + 2])
        }
        XCTAssertGreaterThan(redness(s), redness(s2) + 20)
    }
}

final class GlassRainTests: XCTestCase {
    func testRainCoversTheGlassAndBigDropsRunDown() {
        var glass = GlassRain(width: 800, height: 500)
        for _ in 0..<600 { glass.step(dt: 1 / 30, intensity: 0.8) }
        XCTAssertGreaterThan(glass.drops.count, 100)
        XCTAssertTrue(glass.drops.contains { $0.isSliding })
        XCTAssertTrue(glass.drops.allSatisfy { $0.radius >= 0.35 })
    }

    func testSlidingDropMovesDownAndSwallowsDropsInItsPath() {
        let runner = GlassDrop(x: 100, y: 50, radius: 3.5)
        let sitter = GlassDrop(x: 100, y: 58, radius: 1.5)
        var glass = GlassRain(width: 200, height: 400, drops: [runner, sitter])
        let before = glass.totalVolume
        for _ in 0..<30 { glass.step(dt: 1 / 30, intensity: 0) }
        let biggest = glass.drops.max { $0.radius < $1.radius }!
        XCTAssertGreaterThan(biggest.y, 60)
        XCTAssertGreaterThan(biggest.radius, 3.5) // took in the small drop
        // Water is only lost to a little evaporation.
        XCTAssertEqual(glass.totalVolume, before, accuracy: before * 0.08)
    }

    func testGlassDriesAfterTheRain() {
        var glass = GlassRain(width: 400, height: 300)
        for _ in 0..<300 { glass.step(dt: 0.1, intensity: 1) }
        XCTAssertFalse(glass.drops.isEmpty)
        for _ in 0..<3000 { glass.step(dt: 0.1, intensity: 0) }
        XCTAssertTrue(glass.drops.isEmpty)
    }
}

final class SnowTests: XCTestCase {
    func testSnowBuildsUpAndPilesOnTheLedge() {
        var snow = SnowCover(width: 900)
        snow.setLedge(from: 300, to: 600, height: 70)
        for _ in 0..<2400 { snow.step(dt: 0.5, weather: .sample(.snow)) } // 20 minutes
        let mid = snow.columnCount / 2
        XCTAssertGreaterThan(snow.depth[mid], 5)        // snow on the Dock shelf
        XCTAssertGreaterThan(snow.depth[10], 5)         // and on the ground
        XCTAssertGreaterThanOrEqual(snow.surface(mid), 75)
        // The step at the end of the ledge is never more than a small cornice.
        let edge = Int(300 / snow.columnWidth) + 1
        XCTAssertLessThan(snow.depth[edge], snow.depth[mid])
    }

    func testSnowMeltsWhenItWarms() {
        var snow = SnowCover(width: 300)
        for _ in 0..<1200 { snow.step(dt: 0.5, weather: .sample(.snow)) }
        let deep = snow.totalSnow
        XCTAssertGreaterThan(deep, 0)
        var thaw = WeatherConditions.sample(.rain)
        thaw.temperature = 8
        for _ in 0..<2400 { snow.step(dt: 0.5, weather: thaw) }
        XCTAssertLessThan(snow.totalSnow, deep * 0.05)
    }

    func testLyingSnowFromTheForecastAppears() {
        var w = WeatherConditions.clear
        w.temperature = -2
        w.snowDepth = 0.06
        var snow = SnowCover(width: 300)
        for _ in 0..<1200 { snow.step(dt: 0.5, weather: w) }
        XCTAssertEqual(snow.surface(atX: 150), SnowCover.lyingDepth(snowDepth: 0.06), accuracy: 1)
    }
}

final class LightningTests: XCTestCase {
    func testFlashesComeAndGo() {
        var lit = 0, dark = 0
        for k in 0..<6000 { // one minute at 100 Hz
            if let f = Lightning.flash(at: Double(k) / 100) {
                XCTAssertLessThanOrEqual(f.intensity, 1)
                lit += 1
            } else {
                dark += 1
            }
        }
        XCTAssertGreaterThan(lit, 10)
        XCTAssertGreaterThan(dark, lit * 5)
        XCTAssertEqual(Lightning.flash(at: 12.34)?.seed, Lightning.flash(at: 12.34)?.seed)
    }

    func testBoltReachesTheGround() {
        let segments = Lightning.bolt(seed: 99, x: 0.5, top: 0.2, bottom: 0.9)
        XCTAssertGreaterThan(segments.count, 20)
        XCTAssertGreaterThanOrEqual(segments.map(\.y1).max()!, 0.9)
    }
}

final class WeatherParsingTests: XCTestCase {
    func testSnowDepthIsRead() throws {
        let json = """
        {"current":{"time":1782043200,"temperature_2m":-1.5,"precipitation":0.8,"weather_code":73,
        "cloud_cover":100,"cloud_cover_low":90,"cloud_cover_mid":50,"cloud_cover_high":10,
        "wind_speed_10m":3,"wind_direction_10m":40,"visibility":2000,"snow_depth":0.12}}
        """
        let w = try OpenMeteoProvider.parse(Data(json.utf8))
        XCTAssertEqual(w.snowDepth, 0.12, accuracy: 1e-9)
        XCTAssertEqual(w.precipitation, .snow)
    }
}
