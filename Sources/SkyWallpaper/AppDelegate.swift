#if canImport(AppKit)
import AppKit
import SwiftUI
import Combine
import SkyCore
import IOKit.ps

/// How the sky is put on the desktop.
enum DisplayMode: String, CaseIterable, Identifiable {
    /// Animated window behind the desktop icons (default).
    case live
    /// A still picture set as the normal wallpaper, refreshed every few minutes.
    case still
    /// Live on mains power, still images on battery or in Low Power Mode.
    case automatic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "Live sky"
        case .still: return "Still image"
        case .automatic: return "Live, still on battery"
        }
    }
}

/// Shared, observable state for every screen's sky view and the settings window.
@MainActor
final class SkyModel: ObservableObject {
    @Published var observer: Observer
    @Published var weather: WeatherConditions = .clear
    /// Added to the real clock, so the settings slider can preview any time of day or year.
    @Published var previewOffset: TimeInterval = 0
    /// Frames per second for the live view.
    @Published var frameRate: Double = 30
    @Published var displayMode: DisplayMode =
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .live {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode") }
    }

    let catalog: StarCatalog? = try? StarCatalog.bundled()
    private let weatherService = WeatherService()
    private var weatherTimer: Timer?

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "latitude") != nil {
            observer = Observer(latitude: d.double(forKey: "latitude"), longitude: d.double(forKey: "longitude"))
        } else {
            observer = Observer(latitude: 51.5074, longitude: -0.1278) // placeholder until location is set
        }
    }

    var now: Date { Date().addingTimeInterval(previewOffset) }

    func setLocation(latitude: Double, longitude: Double) {
        observer = Observer(latitude: latitude, longitude: longitude)
        UserDefaults.standard.set(latitude, forKey: "latitude")
        UserDefaults.standard.set(longitude, forKey: "longitude")
        refreshWeather(force: true)
    }

    func startWeather() {
        refreshWeather(force: false)
        weatherTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWeather(force: false) }
        }
    }

    private func refreshWeather(force: Bool) {
        let observer = self.observer
        Task {
            if force { await weatherService.forceNextRefresh() }
            let w = await weatherService.refreshIfNeeded(for: observer)
            self.weather = w
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SkyModel()
    private var statusItem: NSStatusItem?
    private var desktop: DesktopWindowController?
    private var still: StillWallpaperController?
    private var settingsWindow: NSWindow?
    private var modeTimer: Timer?
    private var modeObserver: AnyCancellable?
    private var showingLive: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        desktop = DesktopWindowController(model: model)
        still = StillWallpaperController(model: model)
        model.startWeather()
        applyDisplayMode()
        modeObserver = model.$displayMode.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyDisplayMode() }
        }
        // Re-check power source once a minute (automatic mode) and refresh still images.
        modeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyDisplayMode() }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sun.horizon", accessibilityDescription: "Sky")
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showingLive = nil
                self?.applyDisplayMode()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        still?.restoreOriginalWallpapers()
    }

    private func applyDisplayMode() {
        let live: Bool
        switch model.displayMode {
        case .live: live = true
        case .still: live = false
        case .automatic: live = !PowerState.isConstrained
        }
        if live != showingLive {
            showingLive = live
            if live {
                still?.stop()
                desktop?.showOnAllScreens()
            } else {
                desktop?.hide()
                still?.start()
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Sky Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Whether we should save power: on battery, or Low Power Mode is on.
enum PowerState {
    static var isConstrained: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let source = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return false }
        return (source as String) == "Battery Power"
    }
}
#endif
