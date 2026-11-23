#if canImport(AppKit)
import SwiftUI
import SkyCore

struct SettingsView: View {
    @EnvironmentObject var model: SkyModel
    @State private var latitude = ""
    @State private var longitude = ""

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
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            latitude = String(format: "%.4f", model.observer.latitude)
            longitude = String(format: "%.4f", model.observer.longitude)
        }
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
