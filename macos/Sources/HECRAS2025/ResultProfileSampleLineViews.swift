import SwiftUI

struct ResultProfileSampleLinePanel: View {
    @ObservedObject var session: ResultProfileSession

    private var sources: [ResultProfileSourceChoice] { session.sampleLineSources?.sources ?? [] }
    private var hasMap: Bool { (session.sampleLineSources?.firstFlowAreaCellCount ?? 0) > 0 }
    private var samples: [ChartSample] { ResultProfileSampleLineChartData.samples(for: session.sampleLineSeries) }
    private var chart: SeriesEditorPresentation {
        ResultProfileSampleLineChartData.presentation(for: session.sampleLineSeries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(L10n.text("Sample Line Time Series"), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.headline)
                Spacer()
                Picker(L10n.text("Quantity"), selection: Binding(get: { session.sampleLineMode }, set: session.setSampleLineMode)) {
                    ForEach(ResultProfileSampleLineMode.allCases) { mode in
                        Text(L10n.text(mode.titleKey)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if session.isLoadingSampleLineSources {
                ProgressView(L10n.text("Loading related results…")).controlSize(.small)
            } else if let sources = session.sampleLineSources {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    if let area = sources.firstFlowAreaName {
                        Text(L10n.format("Sample line uses the first embedded 2D flow area: %@ (%d cells / %d faces).",
                            area, sources.firstFlowAreaCellCount, sources.firstFlowAreaFaceCount))
                    } else {
                        Text(L10n.text("Sample line uses the first embedded 2D flow area."))
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary)

                if hasMap {
                    ResultProfileMeshPicker(session: session, flowAreaIndex: 0, elementKind: "Cell",
                        selectedElementIndex: nil, selectElement: { _ in }, sampleLineMode: true,
                        addSampleLinePoint: session.addSampleLinePoint)
                        .frame(minHeight: 260, idealHeight: 330)
                } else {
                    ContentUnavailableView(L10n.text("The first embedded 2D flow area has no selectable mesh cells."),
                        systemImage: "map")
                        .frame(minHeight: 170)
                }

                HStack(spacing: 8) {
                    Button { session.undoSampleLinePoint() } label: {
                        Label(L10n.text("Undo Point"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(session.sampleLinePoints.isEmpty || session.isComputingSampleLine)
                    Button { session.clearSampleLine() } label: {
                        Label(L10n.text("Clear Line"), systemImage: "trash")
                    }
                    .disabled(session.sampleLinePoints.isEmpty || session.isComputingSampleLine)
                    Text(L10n.format("%d sample-line points", session.sampleLinePoints.count))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await session.computeSampleLine() }
                    } label: {
                        Label(L10n.text("Compute Sample Line"), systemImage: "waveform.path.ecg")
                    }
                    .disabled(!hasMap || session.sampleLinePoints.count < 2 || session.isLoadingSampleLineSources
                        || session.isComputingSampleLine)
                }

                if sources.sources.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Related Results")).font(.subheadline.weight(.semibold))
                        Text(L10n.text("Choose results from this embedded plan to overlay their source flow series."))
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(sources.sources) { source in
                                    sourceToggle(source)
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(L10n.text("No related Results are available for this embedded plan."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let error = session.sampleLineError {
                    Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if session.isComputingSampleLine {
                    OperationProgressView(title: "Computing source flow series…",
                        message: session.sampleLineProgressMessage ?? session.sampleLineProgressTaskName ?? "",
                        fraction: session.sampleLineProgressFraction,
                        cancelling: session.isCancellingSampleLine,
                        cancel: session.cancelSampleLineComputation)
                        .padding(.vertical, 6)
                }
                ForEach(session.sampleLineSeries.filter { !$0.available }, id: \.resultPath) { result in
                    Label(L10n.format("%@ could not produce a sample-line series: %@", result.resultName,
                        L10n.text(result.unavailableReason ?? "The source could not compute this sample-line series.")),
                        systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SeriesChartView(samples: samples, presentation: chart,
                    emptyMessage: "Compute the selected Results over the sample line to plot source flow values.")
                    .frame(minHeight: 300)
            } else if let error = session.sampleLineError {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            } else {
                Label(L10n.text("Choose a saved Result in an open project to draw a sample line."),
                    systemImage: "chart.xyaxis.line")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceToggle(_ source: ResultProfileSourceChoice) -> some View {
        let isPrimary = samePath(source.resultPath, session.identity?.resultPath ?? "")
        let key = URL(fileURLWithPath: source.resultPath).standardizedFileURL.resolvingSymlinksInPath().path
        return Toggle(isOn: Binding(get: {
            session.selectedSampleLineResultPaths.contains(key)
        }, set: { session.setSampleLineSource(source.resultPath, selected: $0) })) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: source.resultName).textSelection(.enabled)
                        if isPrimary { Text(L10n.text("Current Result")).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(L10n.format("%d profiles • %@ cells / %@ faces", source.profileCount,
                        source.firstFlowAreaCellCount.formatted(), source.firstFlowAreaFaceCount.formatted()))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(isPrimary || session.isComputingSampleLine)
        .toggleStyle(.checkbox)
    }

    private func samePath(_ first: String, _ second: String) -> Bool {
        URL(fileURLWithPath: first).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: second).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
