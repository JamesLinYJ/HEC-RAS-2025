// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HECRAS2025Mac",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "HECRAS2025", targets: ["HECRAS2025"])],
    targets: [
        .target(name: "RASWorkspaceCore", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .executableTarget(name: "HECRAS2025", dependencies: ["RASWorkspaceCore"],
            resources: [.process("Resources")],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .testTarget(name: "RASWorkspaceCoreTests", dependencies: ["RASWorkspaceCore"],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .testTarget(name: "EditingTests", dependencies: ["HECRAS2025", "RASWorkspaceCore"],
            resources: [.process("Fixtures")],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
    ]
)
