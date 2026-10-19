import AppKit
import SwiftUI

struct AssociatedRasterStyleEditor: View {
    @ObservedObject var session: AssociatedRasterStyleSession
    @State private var newPaletteName = ""
    @State private var paletteToDelete: AssociatedRasterStylePalette?

    var body: some View {
        Group {
            if session.isLoading && session.snapshot == nil {
                ProgressView(L10n.text("Loading raster style"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = session.snapshot, session.draft != nil {
                form(snapshot)
            } else {
                ContentUnavailableView(L10n.text("Raster style unavailable"),
                    systemImage: "slider.horizontal.3",
                    description: Text(session.errorMessage ?? L10n.text("Refresh the selected map layer and try again.")))
            }
        }
        .frame(minWidth: 480, minHeight: 540)
        .task { await session.load() }
        .onDisappear { session.cancelPendingLoad() }
        .alert(L10n.text("Delete custom palette?"), isPresented: Binding(
            get: { paletteToDelete != nil }, set: { if !$0 { paletteToDelete = nil } })) {
            Button(L10n.text("Cancel"), role: .cancel) { paletteToDelete = nil }
            Button(L10n.text("Delete"), role: .destructive) {
                guard let palette = paletteToDelete else { return }
                paletteToDelete = nil
                Task {
                    _ = await session.apply(paletteMutation: AssociatedRasterStylePaletteMutation(
                        action: "deleteCustom", paletteID: palette.id))
                }
            }
        } message: {
            Text(L10n.text("This removes the saved palette from the project visualization settings."))
        }
    }

    @ViewBuilder
    private func form(_ snapshot: AssociatedRasterStyleSnapshot) -> some View {
        Form {
            Section(L10n.text("Palette")) {
                palettePicker(snapshot)
                Picker(L10n.text("Value source"), selection: valueSourceBinding) {
                    ForEach(["Manual", "Linear", "Histogram"], id: \.self) { value in
                        Text(L10n.text(value)).tag(value)
                            .disabled(value == "Histogram" && snapshot.sourceHistogramValues == nil)
                    }
                }
                .disabled(session.isApplying)
                if session.draft?.valueSource == "Histogram" && !snapshot.canComputeHistogram {
                    Label(L10n.text("A source histogram is unavailable for this layer."),
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("Color ramp")) {
                if let stops = session.draft?.stops {
                    ForEach(stops) { stop in
                        stopRow(stop, count: stops.count)
                    }
                }
                HStack {
                    Button(L10n.text("Add color stop"), action: addStop)
                        .disabled((session.draft?.stops.count ?? 0) >= 64 || session.isApplying)
                    Spacer()
                    Button(L10n.text("Remove last stop"), action: removeLastStop)
                        .disabled((session.draft?.stops.count ?? 0) <= 2 || session.isApplying)
                }
            }

            Section(L10n.text("Surface fill")) {
                Toggle(L10n.text("Enable surface fill"), isOn: boolBinding(\.isSurfaceFillEnabled))
                LabeledContent(L10n.text("Alpha")) {
                    Slider(value: doubleBinding(\.alpha, range: 0...255), in: 0...255, step: 1)
                    Text(session.draft.map { String($0.alpha) } ?? "")
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Picker(L10n.text("Interpolation"), selection: stringBinding(\.interpolationMode)) {
                    ForEach(["Nearest", "Linear", "Smooth", "AreaAveraged", "Hybrid"], id: \.self) { value in
                        Text(L10n.text(interpolationLabel(value))).tag(value)
                    }
                }
                numericField(L10n.text("Smoothing radius"), keyPath: \.smoothingRadius,
                    range: 0...1_000_000)
                numericField(L10n.text("Resample cell-size ratio"), keyPath: \.resampleCellSizeRatio,
                    range: 0.01...100)
            }

            Section(L10n.text("Hillshade")) {
                Toggle(L10n.text("Enable hillshade"), isOn: boolBinding(\.hillshadeEnabled))
                numericField(L10n.text("Z factor"), keyPath: \.hillshadeZFactor,
                    range: 0...1_000_000, disabled: session.draft?.hillshadeEnabled != true)
                numericField(L10n.text("Azimuth"), keyPath: \.hillshadeAzimuth,
                    range: 0...360, disabled: session.draft?.hillshadeEnabled != true)
                numericField(L10n.text("Zenith"), keyPath: \.hillshadeZenith,
                    range: 0...90, disabled: session.draft?.hillshadeEnabled != true)
            }

            Section(L10n.text("Contours")) {
                Toggle(L10n.text("Enable contours"), isOn: boolBinding(\.contoursEnabled))
                Toggle(L10n.text("Automatic interval"), isOn: boolBinding(\.contoursAuto))
                    .disabled(session.draft?.contoursEnabled != true)
                numericField(L10n.text("Contour interval"), keyPath: \.contourInterval,
                    range: 0.000001...1_000_000,
                    disabled: session.draft?.contoursEnabled != true || session.draft?.contoursAuto == true)
                integerField(L10n.text("Index every"), keyPath: \.contourIndexEvery,
                    range: 0...1_000, disabled: session.draft?.contoursEnabled != true)
                LabeledContent(L10n.text("Contour color")) {
                    ColorPicker(L10n.text("Color"), selection: contourColorBinding, supportsOpacity: false)
                        .labelsHidden()
                }
                integerField(L10n.text("Contour opacity"), keyPath: \.contourOpacity,
                    range: 0...100, disabled: session.draft?.contoursEnabled != true)
                Toggle(L10n.text("Show contour labels"), isOn: boolBinding(\.contourShowLabels))
                    .disabled(session.draft?.contoursEnabled != true)
                numericField(L10n.text("Contour density"), keyPath: \.contourDensity,
                    range: 0.025...4, disabled: session.draft?.contoursEnabled != true)
            }

            Section(L10n.text("Custom palettes")) {
                HStack {
                    TextField(L10n.text("Palette name"), text: $newPaletteName)
                    Button(L10n.text("Save custom palette")) {
                        let name = newPaletteName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        Task {
                            if await session.apply(paletteMutation: AssociatedRasterStylePaletteMutation(
                                action: "saveCustom", name: name)) {
                                newPaletteName = ""
                            }
                        }
                    }
                    .disabled(session.isApplying || newPaletteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let selected = selectedPalette(snapshot), selected.isCustom {
                    Button(L10n.text("Delete selected custom palette"), role: .destructive) {
                        paletteToDelete = selected
                    }
                    .disabled(session.isApplying)
                }
            }

            if let error = session.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .disabled(session.isApplying || session.isInvalidated)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button(L10n.text("Reset"), action: session.reset)
                    .disabled(session.isApplying || session.isLoading)
                Button(L10n.text("Apply")) {
                    Task { _ = await session.apply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isApplying || session.isLoading || session.isInvalidated)
            }
        }
    }

    @ViewBuilder
    private func palettePicker(_ snapshot: AssociatedRasterStyleSnapshot) -> some View {
        Picker(L10n.text("Surface fill"), selection: paletteIDBinding(snapshot)) {
            Text(L10n.text("Current ramp"))
                .tag(Optional<String>.none)
            ForEach(snapshot.palettes) { palette in
                Text(palettePickerLabel(palette, among: snapshot.palettes))
                    .tag(Optional(palette.id))
                    .disabled(palette.values?.count != palette.colors.count)
            }
        }
    }

    private func palettePickerLabel(_ palette: AssociatedRasterStylePalette,
                                    among palettes: [AssociatedRasterStylePalette]) -> String {
        let displayName = palette.isCustom ? palette.name : L10n.text(palette.name)
        guard palettes.filter({ $0.name == palette.name }).count > 1,
              let values = palette.values, let minimum = values.min(),
              let maximum = values.max() else { return displayName }
        let lower = minimum.formatted(.number.precision(.fractionLength(0...3)))
        let upper = maximum.formatted(.number.precision(.fractionLength(0...3)))
        return "\(displayName) (\(lower)–\(upper))"
    }

    private func stopRow(_ stop: AssociatedRasterStyleColorStop, count: Int) -> some View {
        let allowsValueEdit = session.draft?.valueSource == "Manual"
            || (session.draft?.valueSource == "Linear" && (stop.index == 0 || stop.index == count - 1))
        return HStack {
            Text(L10n.format("Stop %d", stop.index + 1))
                .frame(width: 78, alignment: .leading)
            ColorPicker(L10n.text("Color"), selection: stopColorBinding(stop.index), supportsOpacity: false)
                .labelsHidden()
            TextField(L10n.text("Value"), value: stopValueBinding(stop.index), format: .number)
                .frame(width: 110)
                .disabled(!allowsValueEdit)
        }
    }

    private var valueSourceBinding: Binding<String> {
        Binding(get: { session.draft?.valueSource ?? "Manual" }, set: { value in
            guard value != "Histogram" || session.snapshot?.sourceHistogramValues != nil else { return }
            session.draft?.valueSource = value
            session.draft?.isEditing = true
        })
    }

    private func paletteIDBinding(_ snapshot: AssociatedRasterStyleSnapshot) -> Binding<String?> {
        Binding(get: { session.draft?.paletteID }, set: { identifier in
            guard let identifier else {
                guard session.draft?.paletteID != nil else { return }
                session.draft?.paletteID = nil
                session.draft?.isEditing = true
                return
            }
            guard let palette = snapshot.palettes.first(where: { $0.id == identifier }),
                  let values = palette.values,
                  values.count == palette.colors.count,
                  palette.colors.count >= 2 else { return }
            session.draft?.paletteID = palette.id
            session.draft?.name = palette.name
            session.draft?.valueSource = palette.valueSource
            session.draft?.stops = palette.colors.enumerated().map { index, color in
                AssociatedRasterStyleColorStop(index: index, color: color,
                    value: values[index])
            }
            session.draft?.isEditing = true
        })
    }

    private func selectedPalette(_ snapshot: AssociatedRasterStyleSnapshot) -> AssociatedRasterStylePalette? {
        snapshot.palettes.first { $0.id == session.draft?.paletteID }
    }

    private func stopColorBinding(_ index: Int) -> Binding<Color> {
        Binding(get: {
            guard let color = session.draft?.stops.first(where: { $0.index == index })?.color else { return .clear }
            return Self.color(from: color)
        }, set: { color in
            guard let position = session.draft?.stops.firstIndex(where: { $0.index == index }) else { return }
            session.draft?.stops[position].color = Self.hex(from: color)
            session.draft?.paletteID = nil
            session.draft?.isEditing = true
        })
    }

    private func stopValueBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { session.draft?.stops.first(where: { $0.index == index })?.value ?? 0 }, set: { value in
            guard value.isFinite,
                  let position = session.draft?.stops.firstIndex(where: { $0.index == index }) else { return }
            session.draft?.stops[position].value = value
            session.draft?.paletteID = nil
            session.draft?.isEditing = true
        })
    }

    private var contourColorBinding: Binding<Color> {
        Binding(get: {
            guard let argb = session.draft?.contourColorArgb else { return .black }
            return Color(nsColor: NSColor(calibratedRed: CGFloat((argb >> 16) & 0xff) / 255,
                green: CGFloat((argb >> 8) & 0xff) / 255,
                blue: CGFloat(argb & 0xff) / 255, alpha: 1))
        }, set: { color in
            guard let components = NSColor(color).usingColorSpace(.deviceRGB) else { return }
            let red = Int((components.redComponent * 255).rounded())
            let green = Int((components.greenComponent * 255).rounded())
            let blue = Int((components.blueComponent * 255).rounded())
            session.draft?.contourColorArgb = Int(Int32(bitPattern: UInt32(0xff000000 | (red << 16) | (green << 8) | blue)))
        })
    }

    private func boolBinding(_ keyPath: WritableKeyPath<AssociatedRasterStyleDraft, Bool>) -> Binding<Bool> {
        Binding(get: { session.draft?[keyPath: keyPath] ?? false }, set: { value in
            session.draft?[keyPath: keyPath] = value
            session.draft?.isEditing = true
        })
    }

    private func stringBinding(_ keyPath: WritableKeyPath<AssociatedRasterStyleDraft, String>) -> Binding<String> {
        Binding(get: { session.draft?[keyPath: keyPath] ?? "Linear" }, set: { value in
            session.draft?[keyPath: keyPath] = value
            session.draft?.isEditing = true
        })
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<AssociatedRasterStyleDraft, Int>,
                               range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { Double(session.draft?[keyPath: keyPath] ?? 0) }, set: { value in
            guard value.isFinite, range.contains(value), let sessionDraft = session.draft else { return }
            var edited = sessionDraft
            edited[keyPath: keyPath] = Int(value.rounded())
            edited.isEditing = true
            session.draft = edited
        })
    }

    private func numericField(_ title: String,
                              keyPath: WritableKeyPath<AssociatedRasterStyleDraft, Double>,
                              range: ClosedRange<Double>, disabled: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(title, value: doubleFieldBinding(keyPath, range: range), format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 130)
                .disabled(disabled)
        }
    }

    private func integerField(_ title: String,
                              keyPath: WritableKeyPath<AssociatedRasterStyleDraft, Int>,
                              range: ClosedRange<Int>, disabled: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(title, value: intFieldBinding(keyPath, range: range), format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 130)
                .disabled(disabled)
        }
    }

    private func doubleFieldBinding(_ keyPath: WritableKeyPath<AssociatedRasterStyleDraft, Double>,
                                    range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { session.draft?[keyPath: keyPath] ?? 0 }, set: { value in
            guard value.isFinite, range.contains(value), let sessionDraft = session.draft else { return }
            var edited = sessionDraft
            edited[keyPath: keyPath] = value
            edited.isEditing = true
            session.draft = edited
        })
    }

    private func intFieldBinding(_ keyPath: WritableKeyPath<AssociatedRasterStyleDraft, Int>,
                                 range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { session.draft?[keyPath: keyPath] ?? 0 }, set: { value in
            guard range.contains(value), let sessionDraft = session.draft else { return }
            var edited = sessionDraft
            edited[keyPath: keyPath] = value
            edited.isEditing = true
            session.draft = edited
        })
    }

    private func addStop() {
        guard var draft = session.draft, draft.stops.count < 64,
              let last = draft.stops.last else { return }
        draft.stops.append(AssociatedRasterStyleColorStop(index: draft.stops.count,
            color: last.color, value: last.value + max(abs(last.value) * 0.05, 0.01)))
        draft.isEditing = true
        session.draft = draft
    }

    private func removeLastStop() {
        guard var draft = session.draft, draft.stops.count > 2 else { return }
        draft.stops.removeLast()
        draft.isEditing = true
        session.draft = draft
    }

    private func interpolationLabel(_ value: String) -> String {
        switch value {
        case "AreaAveraged": L10n.text("Area Average")
        default: L10n.text(value)
        }
    }

    private static func color(from raw: String) -> Color {
        let digits = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt64(digits, radix: 16) else { return .clear }
        let alpha, red, green, blue: UInt64
        if digits.count == 8 {
            alpha = (value >> 24) & 0xff
            red = (value >> 16) & 0xff
            green = (value >> 8) & 0xff
            blue = value & 0xff
        } else if digits.count == 6 {
            alpha = 0xff
            red = (value >> 16) & 0xff
            green = (value >> 8) & 0xff
            blue = value & 0xff
        } else { return .clear }
        return Color(nsColor: NSColor(calibratedRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255, blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255))
    }

    private static func hex(from color: Color) -> String {
        guard let components = NSColor(color).usingColorSpace(.deviceRGB) else { return "#FF000000" }
        return String(format: "#%02X%02X%02X%02X",
            Int((components.alphaComponent * 255).rounded()),
            Int((components.redComponent * 255).rounded()),
            Int((components.greenComponent * 255).rounded()),
            Int((components.blueComponent * 255).rounded()))
    }
}
