import SwiftUI

// IntervalPicker uses a number plus day/hour/minute/second/millisecond units.
// Wire values are TimeSpan.TotalSeconds, rounded to the source's 100 ns ticks.
struct IntervalField: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @State private var unit = "Seconds"
    @State private var amount = ""
    @State private var validation: String?
    @State private var committedValue: String?
    private let units: [(String, Double)] = [("Days", 86400), ("Hours", 3600), ("Minutes", 60), ("Seconds", 1), ("Milliseconds", 0.001)]
    var body: some View {
        LabeledContent(LocalizedStringKey(field.title)) {
            HStack {
                TextField("", text: Binding(get: { amount }, set: { amount = $0; commit(showValidation: false) }), prompt: Text(field.mixedBy.flatMap { session.fields[field.scoped($0)] }?.lowercased() == "true" ? "Mixed values" : "—"))
                    .frame(minWidth: 65)
                    .onSubmit { commit(showValidation: true) }
                Picker("Units", selection: Binding(get: { unit }, set: { unit = $0; loadAmount() })) { ForEach(units, id: \.0) { Text(LocalizedStringKey($0.0)).tag($0.0) } }
                    .labelsHidden().frame(width: 120)
            }
        }
        .onAppear(perform: load)
        .onChange(of: session.fields[field.storageID]) { _, value in if value != committedValue { load() } }
        if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
    }
    private func load() {
        guard !field.hasMixedDraft(in: session) else { amount = ""; return }
        if let seconds = Double(session.fields[field.storageID] ?? ""), seconds.isFinite, seconds > 0 {
            let tickValue = (seconds * 10_000_000).rounded(.toNearestOrEven)
            if tickValue < Double(Int64.max), let ticks = Int64(exactly: tickValue) {
                unit = units.first { unit in
                    let unitTicks = Int64(unit.1 * 10_000_000)
                    return unitTicks > 0 && ticks % unitTicks == 0
                }?.0 ?? "Milliseconds"
            }
        }
        loadAmount()
    }
    private func loadAmount() {
        guard !field.hasMixedDraft(in: session) else { amount = ""; return }
        let factor = units.first { $0.0 == unit }?.1 ?? 1
        if let seconds = Double(session.fields[field.storageID] ?? "") { amount = String(seconds / factor) }
        else { amount = "" }
    }
    private func commit(showValidation: Bool) {
        guard let value = Double(amount), value.isFinite, field.allowZero ? value >= 0 : value > 0 else {
            if showValidation { validation = L10n.text(field.allowZero ? "Interval value must not be negative." : "Interval value must be positive.") }; return
        }
        let seconds = value * (units.first { $0.0 == unit }?.1 ?? 1)
        let ticks = (seconds * 10_000_000).rounded(.toNearestOrEven)
        guard ticks.isFinite, ticks < Double(Int64.max) else { if showValidation { validation = L10n.text("The interval is too large.") }; return }
        guard field.allowZero || ticks > 0 else { if showValidation { validation = L10n.text("Interval value must be positive.") }; return }
        let totalSeconds = Double(ticks) / 10_000_000
        let wireValue = String(totalSeconds); committedValue = wireValue
        if Double(session.fields[field.storageID] ?? "") != totalSeconds { field.setDraftValue(wireValue, in: session) }
        validation = nil
    }
}
