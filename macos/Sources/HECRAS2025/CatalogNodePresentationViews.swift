import AppKit
import RASWorkspaceCore
import SwiftUI

/// Uses the macOS file-kind icon for the file connection's extension, matching
/// the source tree's extension-derived icon while staying native to macOS.
struct CatalogNodeIconView: View {
    let symbol: String
    var filePath: String? = nil

    var body: some View {
        if let filePath, !filePath.isEmpty {
            Image(nsImage: NSWorkspace.shared.icon(forFile: filePath))
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Renders the read-only geometry preview for an item in the source backup
/// catalog. The selected backup file is passed to the existing geometry
/// preview provider; the active Geometry editor and its drafts are untouched.
@MainActor
struct CatalogBackupGeometryMeshPreviewView: View {
    let backupPath: String
    let projectURL: URL
    let requestIdentity: String
    let client: BackendProcessClient

    private var asset: ProjectAsset {
        ProjectAsset(url: URL(fileURLWithPath: backupPath), section: .geometries)
    }

    var body: some View {
        CatalogGeometryMeshPreviewView(
            asset: asset,
            projectURL: projectURL,
            requestIdentity: requestIdentity,
            client: client
        )
    }
}
