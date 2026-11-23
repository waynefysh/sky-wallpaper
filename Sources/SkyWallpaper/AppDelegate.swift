#if canImport(AppKit)
import AppKit
import SwiftUI
import SkyCore

/// Shared, observable state for every screen's sky view and the settings window.
@MainActor
final class SkyModel: ObservableObject {
    @Published var observer: Observer
    @Published var weather: WeatherConditions = .clear
    /// Added to the real clock, so the settings slider can preview any time of day or year.
    @Published var previewOffset: TimeInterval = 0
    /// Frames per second for the live view.
    @Published var frameRate: Double = 30

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
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        desktop = DesktopWindowController(model: model)
        desktop?.showOnAllScreens()
        model.startWeather()

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
            Task { @MainActor in self?.desktop?.showOnAllScreens() }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
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
#endif
