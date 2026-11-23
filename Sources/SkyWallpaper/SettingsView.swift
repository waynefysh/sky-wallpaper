#if canImport(AppKit)
import SwiftUI
import Combine
import SkyCore

struct SettingsView: View {
    @EnvironmentObject var model: SkyModel
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var dockAllowed = DockLocator.isTrusted

    var body: some View {
        Form {
            Section("Location") {
                TextField("Latitude (°N)", text: $latitude)
                TextField("Longitude (°E)", text: $longitude)
                Button("Use these coordinates") {
                    if let lat = Double(latitude), let lon = Double(longitude),
                       (-90...90).contains(lat), (-180...180).contains(lon) {
                        model.setLocation(latitude: lat, longitude: lon)
                    }
                }
            }
            Section("Preview") {
                Slider(value: $model.previewOffset, in: -43_200...43_200) {
                    Text("Shift time ±12 h")
                }
                Slider(value: Binding(get: { model.previewOffset / 86_400 },
                                      set: { model.previewOffset = ($0 * 86_400).rounded() }),
                       in: -183...183) {
                    Text("Shift date ±6 months")
                }
                Button("Back to now") { model.previewOffset = 0 }
                Text(sunSummary).font(.caption).foregroundStyle(.secondary)
            }
            Section("Display") {
                Picker("Show the sky as", selection: $model.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Frame rate", selection: $model.frameRate) {
                    Text("15 fps").tag(15.0)
                    Text("30 fps").tag(30.0)
                    Text("60 fps").tag(60.0)
                }
            }
            Section("Weather") {
                Picker("Rain drops on the glass", selection: $model.glassMode) {
                    ForEach(GlassMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Rain and snow on the Dock", isOn: $model.dockEffects)
                if model.dockEffects && !dockAllowed {
                    Text("To find the Dock, Sky needs Accessibility access. Until then, snow settles along the bottom of the screen only.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Allow Accessibility access…") {
                        DockLocator.requestAccess()
                    }
                }
                Picker("Preview weather", selection: $model.weatherPreview) {
                    Text("Live weather").tag(WeatherConditions.Sample?.none)
                    ForEach(WeatherConditions.Sample.allCases, id: \.self) { sample in
                        Text(sample.title).tag(WeatherConditions.Sample?.some(sample))
                    }
                }
                Text(weatherSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            dockAllowed = DockLocator.isTrusted
        }
        .onAppear {
            latitude = String(format: "%.4f", model.observer.latitude)
            longitude = String(format: "%.4f", model.observer.longitude)
        }
    }

    private var weatherSummary: String {
        let w = model.weather
        guard w.observedAt != .distantPast else { return "Waiting for the first weather report." }
        let t = DateFormatter()
        t.timeStyle = .short
        let cloud = Int((max(w.cloudLow, w.cloudMid, w.cloudHigh) * 100).rounded())
        var parts = ["\(String(format: "%.0f", w.temperature))°C", "cloud \(cloud)%"]
        if w.precipitation != .none {
            parts.append("\(w.precipitation.rawValue) \(String(format: "%.1f", w.precipitationRate)) mm/h")
        }
        if w.isThunderstorm { parts.append("thunder") }
        if let v = w.visibility, v < 8_000 { parts.append("visibility \(String(format: "%.1f", v / 1000)) km") }
        if w.snowDepth > 0 { parts.append("snow lying \(Int(w.snowDepth * 100)) cm") }
        return "Live report at \(t.string(from: w.observedAt)): " + parts.joined(separator: ", ")
    }

    private var sunSummary: String {
        let calc = SolarCalculator(observer: model.observer)
        let day = calc.day(containing: model.now)
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let t = DateFormatter()
        t.timeStyle = .short
        let rise = day.sunrise.map(t.string(from:)) ?? "none"
        let set = day.sunset.map(t.string(from:)) ?? "none"
        let alt = calc.position(at: model.now).horizontal.altitude
        return "\(f.string(from: model.now)): sunrise \(rise), sunset \(set), sun at \(String(format: "%.1f", alt))°"
    }
}
#endif
