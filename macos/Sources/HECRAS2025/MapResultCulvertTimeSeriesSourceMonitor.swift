import Combine
import Dispatch
import Foundation
import Darwin

@MainActor
final class MapResultCulvertTimeSeriesSourceMonitor: ObservableObject {
    @Published private(set) var isStale = false

    private let queue = DispatchQueue(label: "com.hecras2025.culvert-time-series-source-watch",
                                      qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var generation = UUID()

    func start(route: MapResultCulvertTimeSeriesWindowRoute) {
        stop()
        isStale = false
        let watchID = UUID()
        generation = watchID
        let request = route.request
        let projectURL = URL(fileURLWithPath: request.map.projectPath)
        let urls = [
            URL(fileURLWithPath: request.resultOwner.selectedResultPath),
            projectURL,
            projectURL.deletingPathExtension().appendingPathExtension("vis")
        ]
        let uniquePaths = Set(urls.map(\.standardizedFileURL.path))
        for path in uniquePaths {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                markStale()
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib],
                queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let source else { return }
                let events = source.data
                Task { @MainActor [weak self] in
                    guard let self, self.generation == watchID else { return }
                    if events.contains(.delete) || events.contains(.rename) {
                        self.markStale()
                        return
                    }
                    let matches = await BackendMapResultCulvertTimeSeriesProvider()
                        .currentSourcesMatch(route)
                    guard self.generation == watchID else { return }
                    if !matches { self.markStale() }
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        Task { [weak self] in
            let matches = await BackendMapResultCulvertTimeSeriesProvider()
                .currentSourcesMatch(route)
            guard let self, self.generation == watchID else { return }
            if !matches { self.markStale() }
        }
    }

    func stop() {
        generation = UUID()
        let active = sources
        sources.removeAll()
        active.forEach { $0.cancel() }
    }

    private func markStale() {
        guard !isStale else { return }
        isStale = true
        stop()
    }
}
