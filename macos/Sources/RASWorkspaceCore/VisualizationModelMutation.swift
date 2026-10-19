import Foundation

public final class PreparedVisualizationModelChange {
    public let affectedNodes: Int
    private let publish: () throws -> Void
    private let restore: () throws -> Void
    private var applied = false
    init(affectedNodes: Int, publish: @escaping () throws -> Void, restore: @escaping () throws -> Void) {
        self.affectedNodes = affectedNodes; self.publish = publish; self.restore = restore
    }
    public func apply() throws { guard !applied else { return }; try publish(); applied = true }
    public func rollback() throws { guard applied else { return }; try restore(); applied = false }
}
