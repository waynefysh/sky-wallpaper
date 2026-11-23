#if canImport(AppKit)
import AppKit
import SwiftUI
import SkyCore

/// Click-through windows above the Dock (and, if chosen, above every window) for the weather
/// that touches things in front of the wallpaper: rain splashing and snow settling on the Dock,
/// and drops running down the glass. They let every click through and never take focus.
@MainActor
final class WeatherOverlayController {
    private let model: SkyModel
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var timer: Timer?

    init(model: SkyModel) {
        self.model = model
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        windows.values.forEach { $0.orderOut(nil) }
        windows = [:]
    }

    /// Re-reads the Dock's position and shows, moves or hides each screen's overlay.
    func refresh() {
        model.effects.updateDock(enabled: model.dockEffects)
        let weather = model.effectiveWeather
        let wet = weather.precipitation != .none || weather.snowDepth > 0
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let id = screen.displayID
            seen.insert(id)
            let fx = model.effects.screen(id, size: screen.frame.size)
            let active = wet || fx.hasVisibleEffects
            let region: CGRect? // in the screen's top-left coordinates
            if model.glassMode == .everything, active {
                region = CGRect(origin: .zero, size: screen.frame.size)
            } else if model.dockEffects, active, let shelf = fx.shelf {
                // The shelf plus room above it for a pile of snow and flying splashes.
                let r = CGRect(x: shelf.minX - 40, y: shelf.minY - 70, width: shelf.width + 80,
                               height: screen.frame.height - (shelf.minY - 70))
                region = r.intersection(CGRect(origin: .zero, size: screen.frame.size))
            } else {
                region = nil
            }
            guard let region, !region.isEmpty else {
                windows[id]?.orderOut(nil)
                windows[id] = nil
                continue
            }
            let frame = CGRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY,
                               width: region.width, height: region.height)
            let full = region.size == screen.frame.size
            if let w = windows[id], let host = w.contentView as? NSHostingView<OverlayRoot>,
               host.rootView.region == region, host.rootView.full == full {
                if w.frame != frame { w.setFrame(frame, display: true) }
                continue
            }
            windows[id]?.orderOut(nil)
            windows[id] = makeWindow(frame: frame, root: OverlayRoot(model: model, screenID: id, region: region, full: full))
        }
        for id in windows.keys where !seen.contains(id) {
            windows[id]?.orderOut(nil)
            windows[id] = nil
        }
    }

    private func makeWindow(frame: CGRect, root: OverlayRoot) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Just above the Dock, below the menu bar, menus and alerts.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // Not on full-screen Spaces, where the Dock is hidden anyway.
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.ignoresMouseEvents = true
        w.isOpaque = false
        w.hasShadow = false
        w.backgroundColor = .clear
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: root)
        w.setFrame(frame, display: true)
        w.orderFrontRegardless()
        return w
    }
}

struct OverlayRoot: View {
    let model: SkyModel
    let screenID: CGDirectDisplayID
    /// The part of the screen this window covers, in the screen's top-left coordinates.
    let region: CGRect
    /// Covers the whole screen, so drops on the glass are drawn here.
    let full: Bool

    var body: some View {
        WeatherOverlayView(screenID: screenID, region: region, full: full).environmentObject(model)
    }
}

/// Draws the weather in front of the Dock: settled snow on its shelf, rain splashing on it,
/// and (when covering the whole screen) drops on the glass.
struct WeatherOverlayView: View {
    @EnvironmentObject var model: SkyModel
    let screenID: CGDirectDisplayID
    let region: CGRect
    let full: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / model.frameRate)) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let weather = model.effectiveWeather
                let screenSize = NSScreen.screens.first { $0.displayID == screenID }?.frame.size
                    ?? CGSize(width: region.maxX, height: region.maxY)
                let fx = model.effects.screen(screenID, size: screenSize)
                fx.advance(to: now, weather: weather, glass: model.glassMode != .off, snowSpeed: model.snowSpeed)
                let scene = SkySceneBuilder(observer: model.observer, catalog: nil)
                    .scene(at: timeline.date.addingTimeInterval(model.previewOffset), weather: weather, includeStars: false)
                let look = WeatherLook(scene: scene)
                let offset = region.origin
                look.paintSnow(&ctx, snow: fx.snow, screenHeight: screenSize.height, onLedge: true, offset: offset)
                if let shelf = fx.shelf {
                    let snow = fx.snow
                    let flat = ScreenWeather.flatTop(of: shelf)
                    look.paintSplashes(&ctx, time: now, from: flat.lowerBound - offset.x, to: flat.upperBound - offset.x, salt: 500) { x in
                        screenSize.height - snow.surface(atX: x + offset.x) - offset.y
                    }
                }
                if full, model.glassMode == .everything {
                    look.paintGlass(&ctx, glass: fx.glass, offset: offset, sample: nil)
                }
            }
        }
        .ignoresSafeArea()
    }
}
#endif
