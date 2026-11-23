#if canImport(AppKit)
import AppKit
import SwiftUI
import SkyCore

/// Still-image mode: renders the current sky to a PNG for each screen and sets it as the
/// normal macOS wallpaper, refreshing every few minutes. Uses almost no power, and the
/// picture also shows where the live window cannot, such as the lock screen.
@MainActor
final class StillWallpaperController {
    private let model: SkyModel
    private var timer: Timer?
    private var originals: [String: URL] = [:]
    private var generation = 0
    var refreshInterval: TimeInterval = 5 * 60

    init(model: SkyModel) {
        self.model = model
    }

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sky", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start() {
        rememberOriginals()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        // macOS caches wallpapers by URL, so alternate between two file names.
        generation += 1
        let date = model.now
        let builder = SkySceneBuilder(observer: model.observer, catalog: model.catalog)
        let scene = builder.scene(at: date, weather: model.weather, includeStars: true)
        let fov = SkyProjection.seasonalFieldOfView(observer: model.observer, date: date)
        for (index, screen) in NSScreen.screens.enumerated() {
            let size = screen.frame.size
            let view = StillSkyView(scene: scene, fov: fov,
                                    background: SkyBackground.image(scene: scene, size: size, fov: fov))
                .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = screen.backingScaleFactor
            guard let cg = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
            let url = folder.appendingPathComponent("sky-\(index)-\(generation % 2).png")
            do {
                try png.write(to: url, options: .atomic)
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch {
                NSLog("Sky: could not set wallpaper: \(error.localizedDescription)")
            }
        }
    }

    /// Records the user's own wallpapers the first time we replace them.
    private func rememberOriginals() {
        for screen in NSScreen.screens {
            let key = screen.localizedName
            if originals[key] == nil, let url = NSWorkspace.shared.desktopImageURL(for: screen),
               !url.path.hasPrefix(folder.path) {
                originals[key] = url
            }
        }
    }

    /// Puts the user's own wallpapers back (on quit).
    func restoreOriginalWallpapers() {
        stop()
        for screen in NSScreen.screens {
            if let url = originals[screen.localizedName] {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
        }
    }
}
#endif
