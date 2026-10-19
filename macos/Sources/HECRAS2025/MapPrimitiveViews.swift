import SwiftUI

/// A provider-backed item for the source map quick-edit wheel. The view never
/// invents choices; an empty source list leaves the center control visible but
/// disabled.
struct MapQuickEditChoice: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let symbol: String
    var detail: String? = nil
    var titleIsUserData = false
    var detailIsUserData = false
}

struct MapQuickEditPickerView: View {
    let choices: [MapQuickEditChoice]
    @Binding var selectedID: String?
    var isEnabled = true
    var onSelect: ((MapQuickEditChoice) -> Void)? = nil
    @State private var isPresented = false

    private var selected: MapQuickEditChoice? { choices.first { $0.id == selectedID } }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: selected?.symbol ?? "slider.horizontal.3")
                Text(selectedTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || choices.isEmpty)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            quickEditWheel
                .frame(width: 280, height: 280)
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
        .help(L10n.text("Quick Edit"))
    }

    private var quickEditWheel: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width, geometry.size.height) * 0.34
            ZStack {
                Circle()
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)

                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(max(choices.count, 1))
                    Button { choose(choice) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: choice.symbol).font(.title3)
                            Text(title(for: choice)).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .frame(width: 76, height: 62)
                        .padding(4)
                        .background(selectedID == choice.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .help(choice.detail.map { choice.detailIsUserData ? $0 : L10n.text($0) } ?? title(for: choice))
                    .position(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
                }

                VStack(spacing: 4) {
                    Image(systemName: selected?.symbol ?? "slider.horizontal.3")
                    Text(selectedTitle)
                        .font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }
                .frame(width: 76, height: 62)
                .background(.regularMaterial, in: Circle())
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(L10n.text("Quick Edit Options"))
    }

    private func title(for choice: MapQuickEditChoice) -> String {
        choice.titleIsUserData ? choice.title : L10n.text(choice.title)
    }

    private var selectedTitle: String {
        selected.map { title(for: $0) } ?? L10n.text("Select a Quick Edit")
    }

    private func choose(_ choice: MapQuickEditChoice) {
        guard isEnabled, choices.contains(where: { $0.id == choice.id }) else { return }
        selectedID = choice.id
        onSelect?(choice)
        isPresented = false
    }
}

struct MapTagPreviewItem: Identifiable, Hashable, Sendable {
    let id: String
    let key: String
    let value: String
}

/// A non-interactive map annotation for the actual selected source tool. The
/// descriptor and help text come from the loaded source tool palette; no
/// placeholder tooltip is drawn when the active tool has no descriptor.
struct MapToolTipAnnotation: View {
    let tool: PaletteToolDescriptor?
    let pointer: CGPoint?
    let canvasSize: CGSize

    private var visibleTool: PaletteToolDescriptor? {
        guard let tool, tool.id != "select" else { return nil }
        return tool
    }

    var body: some View {
        if let tool = visibleTool, let pointer,
           let position = MapToolTipPlacement.position(pointer: pointer,
               canvasSize: canvasSize, panelSize: CGSize(width: 260, height: 88)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(tool.name)).font(.caption.weight(.semibold)).lineLimit(1)
                let help = MapToolText.help(tool.description)
                if !help.isEmpty { Text(help).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
            }
            .frame(width: min(260, max(canvasSize.width - 16, 0)), alignment: .leading)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.7))
            .position(position)
            .accessibilityElement(children: .combine)
            .allowsHitTesting(false)
        }
    }
}

enum MapToolTipPlacement {
    static func position(pointer: CGPoint, canvasSize: CGSize,
                         panelSize: CGSize, verticalOffset: CGFloat = 24) -> CGPoint? {
        guard pointer.x.isFinite, pointer.y.isFinite,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              panelSize.width.isFinite, panelSize.height.isFinite,
              verticalOffset.isFinite, canvasSize.width > 0, canvasSize.height > 0,
              panelSize.width > 0, panelSize.height > 0 else { return nil }
        let margin: CGFloat = 8
        let width = min(panelSize.width, max(canvasSize.width - margin * 2, 1))
        let height = min(panelSize.height, max(canvasSize.height - margin * 2, 1))
        let preferredX = pointer.x + width / 2
        let x = preferredX + width / 2 <= canvasSize.width - margin
            ? preferredX : pointer.x - width / 2
        let preferredY = pointer.y + verticalOffset + height / 2
        let y = preferredY + height / 2 <= canvasSize.height - margin
            ? preferredY : pointer.y - verticalOffset - height / 2
        return CGPoint(x: min(max(x, margin + width / 2), canvasSize.width - margin - width / 2),
                       y: min(max(y, margin + height / 2), canvasSize.height - margin - height / 2))
    }
}

/// Native Tags / Recent Tags / Create New Tag / Assign Tag surface. Tag values
/// and actions are supplied by the selected source feature; absent callbacks
/// keep mutation controls present and disabled.
struct MapTagPreviewView: View {
    let tags: [MapTagPreviewItem]
    let recentTags: [MapTagPreviewItem]
    var maximumRows = 1
    var maximumItems = Int.max
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 4
    var isEnabled = true
    var onAssign: ((Set<String>) -> Void)? = nil
    var onCreate: ((String, String) -> Void)? = nil

    @Binding var selectedTagIDs: Set<String>
    @State private var showingCreate = false
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var recentSelectionID = ""

    private var shownTags: [MapTagPreviewItem] {
        Array(tags.prefix(max(0, maximumItems)))
    }
    private var shownRecents: [MapTagPreviewItem] { recentTags }
    private var availableTagIDs: Set<String> { Set((tags + recentTags).map(\.id)) }
    private var selectedAvailableTagIDs: Set<String> { selectedTagIDs.intersection(availableTagIDs) }
    private var assignmentIDs: Set<String> {
        var ids = selectedAvailableTagIDs
        if shownRecents.contains(where: { $0.id == recentSelectionID }) { ids.insert(recentSelectionID) }
        return ids
    }
    private var canAssign: Bool { isEnabled && onAssign != nil && !assignmentIDs.isEmpty }
    private var canCreate: Bool { isEnabled && onCreate != nil && !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSpacing * 2) {
            HStack {
                Text(L10n.text("Tags (check all that apply)")).font(.headline)
                Spacer()
                Button {
                    showingCreate.toggle()
                } label: {
                    Label(L10n.text("Create New Tag"), systemImage: "plus")
                }
                .disabled(!isEnabled || onCreate == nil)
            }

            if shownTags.isEmpty {
                Text(L10n.text("No Tags"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: verticalSpacing) {
                    ForEach(shownTags) { tag in
                        Toggle(isOn: Binding(
                            get: { selectedTagIDs.contains(tag.id) },
                            set: { selected in
                                if selected { selectedTagIDs.insert(tag.id) }
                                else { selectedTagIDs.remove(tag.id) }
                            })) {
                                HStack(spacing: horizontalSpacing) {
                                    Text(tag.key).fontWeight(.medium)
                                    Text(tag.value).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!isEnabled)
                    }
                    }
                }
                .frame(minHeight: min(28, CGFloat(max(0, maximumRows)) * 28),
                       idealHeight: CGFloat(max(0, maximumRows)) * 28,
                       maxHeight: max(0, CGFloat(maximumRows)) * 28)
            }

            Picker(L10n.text("Recent Tags"), selection: $recentSelectionID) {
                Text(L10n.text("Select a Tag")).tag("")
                ForEach(shownRecents) { tag in
                    Text(tag.key + (tag.value.isEmpty ? "" : ": " + tag.value)).tag(tag.id)
                }
                if !recentSelectionID.isEmpty && !shownRecents.contains(where: { $0.id == recentSelectionID }) {
                    Text(L10n.text("Current Tag Unavailable")).tag(recentSelectionID)
                }
            }
            .disabled(!isEnabled || shownRecents.isEmpty)

            if showingCreate {
                Form {
                    TextField(L10n.text("Key"), text: $newKey)
                    TextField(L10n.text("Value"), text: $newValue)
                    Button(L10n.text("Create New Tag")) { onCreate?(newKey, newValue) }
                        .disabled(!canCreate)
                }
                .formStyle(.columns)
                .disabled(!isEnabled)
            }

            HStack {
                Spacer()
                Button(L10n.text("Assign Tag")) { onAssign?(assignmentIDs) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAssign)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Tags"))
    }
}

/// The source ParticleSettingsMenu binds one mode selector and three sliders
/// directly to VelocityParticlesRenderer.ParticleSettings. Slider ranges are
/// supplied by the caller from the source control; this view does not invent
/// bounds or default values.
enum ParticleVelocityModeOption: String, CaseIterable, Identifiable {
    case perDistance
    case perPixel

    var id: String { rawValue }
    var title: String {
        switch self {
        case .perDistance: "Physical Units"
        case .perPixel: "Screen Units"
        }
    }
}

struct ParticleSettingsValues: Equatable {
    var velocityMode: ParticleVelocityModeOption
    var velocityScalar: Double
    var maxParticleLifetime: Double
    var maxParticles: Int
}

struct ParticleSettingsSliderRanges {
    let velocityScalar: ClosedRange<Double>
    let maxParticleLifetime: ClosedRange<Double>
    let maxParticles: ClosedRange<Double>
}

struct ParticleSettingsMenuView: View {
    @Binding var settings: ParticleSettingsValues
    let ranges: ParticleSettingsSliderRanges
    var isEnabled = true

    var body: some View {
        Form {
            Picker(L10n.text("Velocity Mode"), selection: $settings.velocityMode) {
                ForEach(ParticleVelocityModeOption.allCases) { mode in
                    Text(L10n.text(mode.title)).tag(mode)
                }
            }

            LabeledContent(L10n.text("Velocity Scalar")) {
                Slider(value: $settings.velocityScalar, in: ranges.velocityScalar)
                Text(settings.velocityScalar.formatted(.number.precision(.significantDigits(1...4))))
                    .monospacedDigit().frame(minWidth: 60, alignment: .trailing)
            }

            LabeledContent(L10n.text("Maximum Particle Lifetime")) {
                Slider(value: $settings.maxParticleLifetime, in: ranges.maxParticleLifetime)
                Text(settings.maxParticleLifetime.formatted(.number.precision(.significantDigits(1...4))))
                    .monospacedDigit().frame(minWidth: 60, alignment: .trailing)
            }

            LabeledContent(L10n.text("Maximum Particles")) {
                Slider(value: Binding(
                    get: { Double(settings.maxParticles) },
                    set: { settings.maxParticles = Int($0.rounded()) }
                ), in: ranges.maxParticles, step: 1)
                Text(settings.maxParticles.formatted())
                    .monospacedDigit().frame(minWidth: 60, alignment: .trailing)
            }
        }
        .formStyle(.grouped)
        .disabled(!isEnabled)
    }
}

/// A render-only counterpart to the source particle canvas. Positions are
/// normalized map-canvas coordinates and come from a real velocity-particle
/// provider; an empty snapshot remains transparent and never seeds fake paths.
struct VelocityParticleTrace: Identifiable {
    let id: String
    let lastPosition: CGPoint
    let position: CGPoint
    let lifetime: Double
}

struct VelocityParticlesRendererView: View {
    let traces: [VelocityParticleTrace]
    let maxParticleLifetime: Double
    var isEnabled = true

    var body: some View {
        Canvas { context, size in
            guard self.isEnabled, self.maxParticleLifetime.isFinite, self.maxParticleLifetime > 0 else { return }

            for trace in self.traces {
                guard trace.lifetime.isFinite, trace.lifetime >= 0,
                      self.finite(trace.lastPosition), self.finite(trace.position),
                      let width = self.sourceStrokeWidth(lifetime: trace.lifetime) else { continue }

                var path = Path()
                path.move(to: CGPoint(x: trace.lastPosition.x * size.width, y: trace.lastPosition.y * size.height))
                path.addLine(to: CGPoint(x: trace.position.x * size.width, y: trace.position.y * size.height))
                context.stroke(path, with: .color(.white.opacity(0.6)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sourceStrokeWidth(lifetime: Double) -> CGFloat? {
        let widthLifetime = min(maxParticleLifetime, 0.25)
        guard widthLifetime > 0 else { return nil }
        let lifetimeRatio = min(lifetime / widthLifetime, 1)
        let fullWidthEnd = maxParticleLifetime
        let taperStart = fullWidthEnd - fullWidthEnd * 0.15
        let taperRange = fullWidthEnd - taperStart
        guard taperRange > 0 else { return nil }
        let clamped = min(max(lifetime, taperStart), fullWidthEnd)
        let taper = 1 - (clamped - taperStart) / taperRange
        let result = lifetimeRatio * taper * 2
        guard result.isFinite, result > 0 else { return nil }
        return CGFloat(result)
    }

    private func finite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}
