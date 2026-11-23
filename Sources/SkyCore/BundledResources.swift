import Foundation

/// Finds SkyCore's bundled data (star catalogue, Moon map).
///
/// SwiftPM's `Bundle.module` looks next to the executable, which works for `swift run` but not
/// inside a packaged `.app`, where the resource bundle lives in `Contents/Resources` (the only
/// place code signing allows it). `Bundle.module` also stops the app if it finds nothing, so
/// the packaged location is checked first.
enum BundledResources {
    static let bundleName = "SkyWallpaper_SkyCore.bundle"

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent(bundleName)) {
            return packaged.url(forResource: name, withExtension: ext)
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
