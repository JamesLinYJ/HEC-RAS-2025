import Foundation

/// Retained RasApplicationData generates a ten-character lowercase
/// alphanumeric UID when no persistent value exists. Persistence and the
/// `--first-launch` suppression policy stay with WorkspaceStore.
enum WorkspaceApplicationIdentity {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz1234567890")

    static func generateUID(using random: inout some RandomNumberGenerator) -> String {
        String((0..<10).compactMap { _ in alphabet.randomElement(using: &random) })
    }

    static func generateUID() -> String {
        var random = SystemRandomNumberGenerator()
        return generateUID(using: &random)
    }
}
