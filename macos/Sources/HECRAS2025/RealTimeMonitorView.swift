import Charts
import SwiftUI

struct MonitorObservation: Identifiable {
    let id: Int
    let date: Date
    let value: Double
}
@MainActor
final class MonitorHistory: ObservableObject {
    @Published private(set) var observations: [MonitorObservation] = []
    @Published private(set) var minimum: Double?
    @Published private(set) var maximum: Double?
    private var nextID = 0
    private var context: String?
    let capacity: Int
    init(capacity: Int = 10_000) { self.capacity = max(1, capacity) }
    func configure(_ identity: String) { if context != identity { context = identity; clear() } }
    func record(_ value: Double?, at date: Date) {
        guard let value, value.isFinite, date.timeIntervalSince1970.isFinite else { return }
        observations.append(.init(id: nextID, date: date, value: value)); nextID += 1
        minimum = min(minimum ?? value, value); maximum = max(maximum ?? value, value)
        if observations.count > capacity { observations.removeFirst(observations.count - capacity) }
    }
    func clear() { observations = []; minimum = nil; maximum = nil }
}

// RealTimeMonitor polls only an actual source value while its source running
// flag is true. Observed timestamps are UI observations, not solver timesteps.
struct RealTimeMonitorView: View {
    let title: String
    let field: String
    let units: String
    // The source chart initializes its dataset with Color.LimeGreen and a
    // 1.5-point stroke. Keep those defaults until a source color is provided.
    var lineColor = Color(red: 50.0 / 255.0, green: 205.0 / 255.0, blue: 50.0 / 255.0)
    @ObservedObject var session: ModelEditorSession
    @StateObject private var history = MonitorHistory()
    @State private var rangeSeconds = 0
    private var running: Bool { session.fields["IsComputeRunning"]?.lowercased() == "true" }
    private var identity: String { (session.modelAssetID ?? "") + "/" + (session.fields["Job_ID"] ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LocalizedStringKey(title)).font(.headline)
                Spacer()
                Picker("Time Range", selection: $rangeSeconds) {
                    Text("All").tag(0); Text("30 seconds").tag(30); Text("1 minute").tag(60); Text("5 minutes").tag(300)
                }.labelsHidden().frame(width: 120)
                Button("Clear") { history.clear() }.disabled(history.observations.isEmpty)
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                let values = history.observations.filter { rangeSeconds == 0 || $0.date >= timeline.date.addingTimeInterval(-Double(rangeSeconds)) }
                Chart(values) { item in
                    LineMark(x: .value("Observation Time", item.date), y: .value(title, item.value))
                        .foregroundStyle(lineColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }.chartYAxisLabel(L10n.text("Value")).frame(height: 140)
                    .overlay { if values.isEmpty { Text("No observed values").font(.caption).foregroundStyle(.secondary) } }
            }
            HStack {
                if let value = history.minimum { Text(L10n.format("Minimum: %@", format(value))) }
                Spacer()
                if let value = history.maximum { Text(L10n.format("Maximum: %@", format(value))) }
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("Refresh interval: 1 second").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: identity + "/" + String(running)) {
            history.configure(identity)
            guard running else { return }
            while !Task.isCancelled {
                history.record(Double(session.fields[field] ?? ""), at: .now)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func format(_ value: Double) -> String { value.formatted(.number.precision(.significantDigits(1...4))) + (units.isEmpty ? "" : " " + units) }
}

// PauseContinueStop renders only source-supported commands. IsStopped disables
// further commands; issuing a command does not manufacture a running result.
struct PlaybackControls: View {
    var isPaused = false
    var isStopped = false
    var allowPlayPause = false
    var pending = false
    var pause: (() -> Void)? = nil
    var resume: (() -> Void)? = nil
    var stop: (() -> Void)? = nil
    var body: some View {
        ControlGroup {
            if allowPlayPause {
                if isPaused { Button("Continue", systemImage: "play.fill") { resume?() }.disabled(resume == nil) }
                else { Button("Pause", systemImage: "pause.fill") { pause?() }.disabled(pause == nil) }
            }
            Button("Stop", systemImage: "stop.fill") { stop?() }.disabled(stop == nil)
        }.disabled(pending || isStopped)
    }
}
