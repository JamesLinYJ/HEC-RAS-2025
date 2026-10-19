import AppKit
import RASWorkspaceCore
import UniformTypeIdentifiers

enum AttributeTableCloseDecision { case export, cancel, discard }

struct ClipboardItem: Sendable { let representations: [String: Data] }

@MainActor
protocol WorkspaceSystemServices {
    func chooseProject() -> URL?
    func authorizeProjectFolder(for input: URL) -> URL?
    func authorizeExternalFolders(_ folders: [URL]) -> Bool
    func chooseProjectDestination(name: String) -> URL?
    func chooseExportDestination(name: String, extensions: [String], title: String) -> URL?
    func chooseFolder(title: String) -> URL?
    func chooseVectorLayer() -> URL?
    func chooseMapLayer() -> URL?
    func chooseConnectionFile() -> URL?
    func chooseConnectionFiles() -> [URL]
    func chooseAttributeTableFile() -> URL?
    func authorizeAttributeTableFolder(for input: URL) -> URL?
    func confirmAttributeTableClose(name: String) -> AttributeTableCloseDecision
    func chooseInputFiles() -> [URL]
    func choosePointShapefile() -> URL?
    func chooseImageFiles() -> [URL]
    func chooseBugScreenshots() -> [URL]
    func chooseProjectionFile() -> URL?
    func chooseInitialConditionsResult() -> URL?
    func chooseProjectionSourceFiles() -> [URL]
    func reveal(_ url: URL)
    func trash(_ url: URL) throws
    func copy(_ text: String)
    func openWebsite(_ url: URL)
    func openFile(_ url: URL)
    func toggleFullScreen()
    var isTextInputActive: Bool { get }
    func readClipboard(types: [String]) -> [ClipboardItem]
    func writeClipboard(_ items: [ClipboardItem]) -> Bool
}
extension WorkspaceSystemServices {
    func chooseMapLayer() -> URL? { chooseVectorLayer() }
    func chooseInitialConditionsResult() -> URL? { chooseConnectionFile() }
    func chooseProjectionSourceFiles() -> [URL] { chooseProjectionFile().map { [$0] } ?? [] }
    func trash(_ url: URL) throws { throw CocoaError(.featureUnsupported) }
    func chooseAttributeTableFile() -> URL? { chooseConnectionFile() }
    func authorizeAttributeTableFolder(for input: URL) -> URL? { input }
    func confirmAttributeTableClose(name: String) -> AttributeTableCloseDecision { .cancel }
    func chooseConnectionFiles() -> [URL] { chooseConnectionFile().map { [$0] } ?? [] }
    func chooseBugScreenshots() -> [URL] { chooseImageFiles().filter { ["png", "jpeg", "jpg"].contains($0.pathExtension.lowercased()) } }
    func chooseExportDestination(name: String, extensions: [String], title: String) -> URL? { nil }
    func authorizeProjectFolder(for input: URL) -> URL? { input }
    func authorizeExternalFolders(_ folders: [URL]) -> Bool { true }
    func choosePointShapefile() -> URL? { chooseInputFiles().first { $0.pathExtension.lowercased() == "shp" } }
    func openFile(_ url: URL) { reveal(url) }
    func toggleFullScreen() {}
    var isTextInputActive: Bool { false }
    func readClipboard(types: [String]) -> [ClipboardItem] { [] }
    func writeClipboard(_ items: [ClipboardItem]) -> Bool { false }
}

// All Cocoa-specific services are confined to this file. Views and portable
// document/path logic never invoke explorer.exe, WinRT, registry, or drive APIs.
@MainActor
final class MacSystemServices: WorkspaceSystemServices {
    private var projectFolders: [String: URL] = [:]
    private var scopedFolders: [URL] = []
    deinit { for url in scopedFolders { url.stopAccessingSecurityScopedResource() } }
    private func retainFolder(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard projectFolders[key] == nil else { return }
        if url.startAccessingSecurityScopedResource() { scopedFolders.append(url) }
        projectFolders[key] = url
    }
    private func hasFolderAccess(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        return projectFolders.values.contains { parts.starts(with: $0.standardizedFileURL.pathComponents) }
    }
    func authorizeExternalFolders(_ folders: [URL]) -> Bool {
        for folder in folders where !hasFolderAccess(folder) {
            let panel = NSOpenPanel()
            panel.title = L10n.text("Open External Data Folder")
            panel.message = L10n.text("Select this folder to read the required external data.")
            panel.directoryURL = folder
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.prompt = L10n.text("Open External Data Folder")
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            guard chosen.standardizedFileURL == folder.standardizedFileURL else {
                let alert = NSAlert(); alert.messageText = L10n.text("Select the requested external data folder."); alert.runModal(); return false
            }
            retainFolder(chosen)
        }
        return true
    }
    func authorizeProjectFolder(for input: URL) -> URL? {
        let isFolder = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let folder = isFolder ? input : input.deletingLastPathComponent()
        if hasFolderAccess(folder) { return input }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Open Project Folder")
        panel.message = L10n.text("Select this project's folder to open its related files.")
        panel.directoryURL = folder
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Open Project Folder")
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        guard chosen.standardizedFileURL == folder.standardizedFileURL else {
            let alert = NSAlert(); alert.messageText = L10n.text("Select the folder containing the chosen project."); alert.runModal()
            return nil
        }
        retainFolder(chosen)
        return input
    }
    var isTextInputActive: Bool { NSApp.keyWindow?.firstResponder is NSTextView }
    func readClipboard(types: [String]) -> [ClipboardItem] {
        guard !types.isEmpty else { return [] }
        return (NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
            var representations: [String: Data] = [:]
            for type in types { if let data = item.data(forType: NSPasteboard.PasteboardType(type)) { representations[type] = data } }
            return representations.isEmpty ? nil : ClipboardItem(representations: representations)
        }
    }
    func writeClipboard(_ items: [ClipboardItem]) -> Bool {
        let values = items.compactMap { value -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            for (type, data) in value.representations where !type.isEmpty { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item.types.isEmpty ? nil : item
        }
        guard !values.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects(values)
    }
    func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }
    func openFile(_ url: URL) { if url.isFileURL { NSWorkspace.shared.open(url) } }
    func choosePointShapefile() -> URL? {
        let panel = NSOpenPanel(); panel.title = L10n.text("Import POI Shapefile")
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "shp") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
    func openWebsite(_ url: URL) { if ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) } }
    func chooseProject() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Open Project")
        panel.message = L10n.text("Choose a HEC-RAS project, a v6 .prj project to migrate, a ZIP project, an HDF5 core file, or a project folder.")
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ras") ?? .data,
                                     UTType(filenameExtension: "prj") ?? .plainText,
                                     UTType(filenameExtension: "zip") ?? .archive,
                                     UTType(filenameExtension: "h5") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { retainFolder(url) }
        return url
    }
    func chooseProjectDestination(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.text("Save Project As")
        panel.nameFieldStringValue = name + ".ras"
        panel.allowedContentTypes = [UTType(filenameExtension: "ras") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.pathExtension.lowercased() == "ras" ? url : url.appendingPathExtension("ras")
    }
    func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel(); panel.title = L10n.text(title)
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        retainFolder(url); return url
    }
    func chooseExportDestination(name: String, extensions: [String], title: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.text(title); panel.nameFieldStringValue = name
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    func chooseVectorLayer() -> URL? {
        let panel = NSOpenPanel(); panel.title = L10n.text("Add Map Layer")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "geojson") ?? .data,
                                     UTType(filenameExtension: "shp") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
    func chooseMapLayer() -> URL? {
        let panel = NSOpenPanel(); panel.title = L10n.text("Add Map Layer")
        // A File Geodatabase is a directory package, while its manifest/data
        // members may be selected in Finder-style navigation. Accept either
        // and normalize the result to the containing .gdb root downstream.
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .tiff, UTType(filenameExtension: "geojson") ?? .data,
                                     UTType(filenameExtension: "shp") ?? .data, .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
    func chooseConnectionFile() -> URL? {
        let panel = NSOpenPanel(); panel.title = L10n.text("File Connection")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    func authorizeAttributeTableFolder(for input: URL) -> URL? {
        let folder = input.deletingLastPathComponent()
        if hasFolderAccess(folder) { return input }
        let panel = NSOpenPanel(); panel.title = L10n.text("Open Shapefile Folder")
        panel.message = L10n.text("Select the Shapefile's folder so its related attribute and index files can be read.")
        panel.directoryURL = folder; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Open Shapefile Folder")
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        guard chosen.standardizedFileURL == folder.standardizedFileURL else {
            let alert = NSAlert(); alert.messageText = L10n.text("Select the folder containing the selected Shapefile."); alert.runModal(); return nil
        }
        retainFolder(chosen); return input
    }
    func chooseAttributeTableFile() -> URL? {
        let panel = NSOpenPanel(); panel.title = L10n.text("Open Attribute Table")
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "shp") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
    func confirmAttributeTableClose(name: String) -> AttributeTableCloseDecision {
        let alert = NSAlert(); alert.messageText = L10n.format("Export changes to %@?", name)
        alert.informativeText = L10n.text("The edited table can be exported as CSV. The source shapefile is unchanged.")
        alert.addButton(withTitle: L10n.text("Export Table…")); alert.addButton(withTitle: L10n.text("Cancel")); alert.addButton(withTitle: L10n.text("Discard"))
        switch alert.runModal() { case .alertFirstButtonReturn: return .export; case .alertThirdButtonReturn: return .discard; default: return .cancel }
    }
    func chooseConnectionFiles() -> [URL] {
        let panel = NSOpenPanel(); panel.title = L10n.text("File Connections")
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
    func chooseInputFiles() -> [URL] {
        let panel = NSOpenPanel(); panel.title = L10n.text("Input Files")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
    func chooseImageFiles() -> [URL] {
        let panel = NSOpenPanel(); panel.title = L10n.text("Add Image")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.urls : []
    }
    func chooseInitialConditionsResult() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose Initial Conditions Result")
        panel.message = L10n.text("Choose a prior RAS result HDF file.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "h5") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
    func chooseProjectionFile() -> URL? {
        let panel = NSOpenPanel(); panel.title = L10n.text("Read PRJ File")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "prj") ?? .plainText]
        return panel.runModal() == .OK ? panel.url : nil
    }
    func chooseProjectionSourceFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose Projection Source")
        panel.message = L10n.text("Choose a project, model, raster, or projection file.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
    func chooseBugScreenshots() -> [URL] {
        let panel = NSOpenPanel(); panel.title = L10n.text("Screenshots")
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg]
        return panel.runModal() == .OK ? panel.urls : []
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func trash(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
