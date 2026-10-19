import Charts
import SwiftUI

/// One dated interval rendered by SourceTimelineView. A missing endpoint uses
/// the current visible timeline extent, matching the source control's default
/// end-time behavior.
struct SourceTimelineEntry: Identifiable {
    let id: String
    var name: String
    var startTime: Date?
    var endTime: Date?
    var color: Color = .blue
}

/// Native interval timeline corresponding to Visual.Core.WinUI Timeline.
/// The primary interval and date axis remain visible when `entries` is empty.
struct SourceTimelineView: View {
    let primaryLineName: String
    let startTime: Date?
    let endTime: Date?
    let entries: [SourceTimelineEntry]
    var primaryLineColor: Color = .accentColor
    var lineHeight: CGFloat = 2
    var lineSpacing: CGFloat = 24

    private struct Track: Identifiable {
        let id: String
        let name: String
        let start: Date
        let end: Date
        let color: Color
        var accessibleRange: String {
            let startText: String = start.formatted(date: .numeric, time: .shortened)
            let endText: String = end.formatted(date: .numeric, time: .shortened)
            return startText + " – " + endText
        }
    }

    private var domain: ClosedRange<Date>? {
        let dates = [startTime, endTime]
            .compactMap { $0 }
            + entries.flatMap { [$0.startTime, $0.endTime].compactMap { $0 } }
        guard let lower = dates.min(), let upper = dates.max() else { return nil }
        if lower < upper { return lower...upper }
        return lower.addingTimeInterval(-30)...upper.addingTimeInterval(30)
    }

    private var tracks: [Track] {
        guard let domain else { return [] }
        var result = [Track(
            id: "timeline:primary",
            name: primaryLineName.isEmpty ? L10n.text("Timeline") : primaryLineName,
            start: startTime ?? domain.lowerBound,
            end: endTime ?? domain.upperBound,
            color: primaryLineColor
        )]
        result += entries.compactMap { entry in
            let start = entry.startTime ?? domain.lowerBound
            let end = entry.endTime ?? domain.upperBound
            guard start <= end else { return nil }
            return Track(id: "timeline:entry:" + entry.id, name: entry.name, start: start, end: end, color: entry.color)
        }
        return result
    }

    private var trackPositions: [Double] { tracks.indices.map { Double($0) } }

    private var timelineYAxis: AxisMarks<AxisValueLabel<Text>> {
        let labels = tracks.map(\.name)
        return AxisMarks(position: .leading, values: trackPositions) { (value: AxisValue) in
            let coordinate = value.as(Double.self) ?? -1
            let valid = coordinate.isFinite && coordinate >= 0 && coordinate < Double(labels.count)
            let title = valid ? labels[Int(coordinate)] : ""
            AxisValueLabel { Text(verbatim: title) }
        }
    }

    @ChartContentBuilder private func timelineMark(_ track: Track, index: Int) -> some ChartContent {
        BarMark(xStart: .value("Start Time", track.start), xEnd: .value("End Time", track.end),
                y: .value("Timeline", Double(index)), height: .fixed(max(lineHeight, 4)))
            .foregroundStyle(track.color)
            .accessibilityLabel(Text(verbatim: track.name))
            .accessibilityValue(Text(verbatim: track.accessibleRange))
    }

    var body: some View {
        Group {
            if let domain, !tracks.isEmpty {
                Chart {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        timelineMark(track, index: index)
                    }
                }
                .chartXScale(domain: domain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: Date.FormatStyle.dateTime.month(.twoDigits).day().year(.twoDigits).hour().minute())
                    }
                }
                .chartYAxis { timelineYAxis }
                .frame(minHeight: max(100, CGFloat(tracks.count) * max(lineSpacing, 18)))
                .accessibilityLabel(Text(primaryLineName.isEmpty ? L10n.text("Timeline") : primaryLineName))
            } else {
                Text("No timeline range is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            }
        }
    }
}

/// Date pair and elapsed-time readout corresponding to Visual.Core.WinUI
/// TimeDifference. Units follow the source's d/h/m/s/ms presentation.
struct TimeDifferenceView: View {
    let startTime: Date
    let endTime: Date

    var body: some View {
        HStack(spacing: 14) {
            LabeledContent("Start Time", value: startTime.formatted(.dateTime.year().month().day().hour().minute().second()))
            LabeledContent("End Time", value: endTime.formatted(.dateTime.year().month().day().hour().minute().second()))
            LabeledContent("Time Difference", value: prettyDifference)
        }
        .font(.caption.monospacedDigit())
        .textSelection(.enabled)
    }

    private var prettyDifference: String {
        let elapsed = endTime.timeIntervalSince(startTime)
        guard elapsed.isFinite else { return "—" }
        let scaled = (elapsed * 1_000).rounded(.towardZero)
        guard scaled.isFinite, scaled >= Double(Int64.min), scaled < Double(Int64.max) else { return "—" }
        let totalMilliseconds = Int64(scaled)
        guard totalMilliseconds != 0 else { return L10n.text("No Time") }

        let isNegative = totalMilliseconds < 0
        var remainder = totalMilliseconds.magnitude
        let units: [(UInt64, String)] = [
            (86_400_000, "d"),
            (3_600_000, "h"),
            (60_000, "m"),
            (1_000, "s"),
            (1, "ms")
        ]
        var parts: [String] = []
        for (size, label) in units {
            let value = remainder / size
            remainder %= size
            if value > 0 { parts.append("\(value)\(label)") }
        }
        return (isNegative ? "−" : "") + parts.joined(separator: " ")
    }
}

enum SlidePickerDirection: Equatable {
    case left
    case right
}

/// Source SlidePickerItem data for a native picker. Its arbitrary source
/// content is represented by a concise title, optional detail, and symbol.
struct SlidePickerItemPresentation: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String? = nil
    var systemImage: String? = nil
}

enum SharedVisualSlidePickerSelection {
    static func normalizedIndex(_ index: Int, itemCount: Int) -> Int {
        itemCount == 0 ? -1 : min(max(index, 0), itemCount - 1)
    }

    static func nextIndex(_ index: Int, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        let current = normalizedIndex(index, itemCount: itemCount)
        return (current + 1) % itemCount
    }

    static func orderedUniqueItems(_ items: [SlidePickerItemPresentation]) -> [SlidePickerItemPresentation] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

struct SlidePickerItemView: View {
    let item: SlidePickerItemPresentation
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage = item.systemImage {
                Image(systemName: systemImage).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title).fontWeight(isSelected ? .semibold : .regular)
                if let detail = item.detail {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if isSelected {
                Spacer(minLength: 8)
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Native selected-face/menu equivalent of Visual.Core.WinUI SlidePicker.
/// Selection is keyed by source-stable item identity, not by view order.
struct SlidePickerView: View {
    let items: [SlidePickerItemPresentation]
    private let selectedID: Binding<String?>?
    private let selectedIndex: Binding<Int>?
    var direction: SlidePickerDirection = .right

    private var orderedItems: [SlidePickerItemPresentation] {
        SharedVisualSlidePickerSelection.orderedUniqueItems(items)
    }

    init(items: [SlidePickerItemPresentation], selectedID: Binding<String?>, direction: SlidePickerDirection = .right) {
        self.items = items
        self.selectedID = selectedID
        selectedIndex = nil
        self.direction = direction
    }

    /// Source SlidePicker is index-backed. Reordering `items` keeps the
    /// selected index and therefore selects the item now occupying that slot.
    init(items: [SlidePickerItemPresentation], selectedIndex: Binding<Int>, direction: SlidePickerDirection = .right) {
        self.items = items
        selectedID = nil
        self.selectedIndex = selectedIndex
        self.direction = direction
    }

    private var currentIndex: Int? {
        if let selectedIndex {
            return orderedItems.indices.contains(selectedIndex.wrappedValue) ? selectedIndex.wrappedValue : nil
        }
        if let selectedID, let index = orderedItems.firstIndex(where: { $0.id == selectedID.wrappedValue }) {
            return index
        }
        return orderedItems.isEmpty ? nil : 0
    }

    private var selectedItem: SlidePickerItemPresentation? {
        guard let currentIndex else { return nil }
        return orderedItems[currentIndex]
    }

    var body: some View {
        HStack {
            if direction == .right { Spacer(minLength: 0) }
            if let selectedItem {
                if orderedItems.count > 1 {
                    HStack(spacing: 4) {
                        Button {
                            guard let currentIndex else { return }
                            guard let next = SharedVisualSlidePickerSelection.nextIndex(currentIndex, itemCount: orderedItems.count) else { return }
                            select(index: next)
                        } label: {
                            SlidePickerItemView(item: selectedItem, isSelected: true)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Next slide"))
                        .accessibilityValue(Text(selectedItem.title))

                        Menu {
                            ForEach(orderedItems.filter { $0.id != selectedItem.id }) { item in
                                Button {
                                    guard let index = orderedItems.firstIndex(where: { $0.id == item.id }) else { return }
                                    select(index: index)
                                } label: {
                                    SlidePickerItemView(item: item)
                                }
                            }
                        } label: {
                            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 30)
                        }
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel(Text("Choose a slide"))
                    }
                } else {
                    SlidePickerItemView(item: selectedItem, isSelected: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
            } else {
                Text("No slide options are available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if direction == .left { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: normalizeSelection)
        .onChange(of: orderedItems.map(\.id)) { _, _ in normalizeSelection() }
        .onChange(of: selectedID?.wrappedValue) { _, _ in normalizeSelection() }
        .onChange(of: selectedIndex?.wrappedValue) { _, _ in normalizeSelection() }
    }

    private func normalizeSelection() {
        if let selectedIndex {
            let normalized = SharedVisualSlidePickerSelection.normalizedIndex(selectedIndex.wrappedValue, itemCount: orderedItems.count)
            if selectedIndex.wrappedValue != normalized { selectedIndex.wrappedValue = normalized }
            return
        }
        guard let selectedID else { return }
        guard orderedItems.contains(where: { $0.id == selectedID.wrappedValue }) else {
            if selectedID.wrappedValue != orderedItems.first?.id { selectedID.wrappedValue = orderedItems.first?.id }
            return
        }
    }

    private func select(index: Int) {
        guard orderedItems.indices.contains(index) else { return }
        if let selectedIndex {
            selectedIndex.wrappedValue = index
        } else {
            selectedID?.wrappedValue = orderedItems[index].id
        }
    }
}
