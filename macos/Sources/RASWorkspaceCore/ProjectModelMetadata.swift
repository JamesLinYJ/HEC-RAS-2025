import Foundation

public struct ProjectModelMetadataMutation: Equatable, Sendable {
    public let section: String
    public let rowName: String
    public let identityAttribute: String
    public let identityValue: String
    public let attribute: String
    public let oldValue: String?
    public let newValue: String?
    public let removeRow: Bool
    public init(section: String, rowName: String, identityAttribute: String, identityValue: String,
        attribute: String, oldValue: String?, newValue: String?, removeRow: Bool = false) {
        self.section = section; self.rowName = rowName; self.identityAttribute = identityAttribute
        self.identityValue = identityValue; self.attribute = attribute
        self.oldValue = oldValue; self.newValue = newValue; self.removeRow = removeRow
    }
}

/// A model file publication can fail before its final Trash step. This prepared
/// change applies or rolls back only the affected XML attributes/rows, retaining
/// unrelated nodes and their runtime identities. It never saves a project file.
public final class PreparedProjectModelMetadataChange {
    private let validateCurrent: () -> Bool
    private let applyChanges: () -> Void
    private let revertChanges: () -> Void
    private var applied = false
    init(validateCurrent: @escaping () -> Bool, apply: @escaping () -> Void, rollback: @escaping () -> Void) {
        self.validateCurrent = validateCurrent; applyChanges = apply; revertChanges = rollback
    }
    public func apply() throws {
        guard !applied, validateCurrent() else { throw ProjectFileError.modifiedExternally }
        applyChanges(); applied = true
    }
    public func rollback() {
        guard applied else { return }
        revertChanges(); applied = false
    }
}
