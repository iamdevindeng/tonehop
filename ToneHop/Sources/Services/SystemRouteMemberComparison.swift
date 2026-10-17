import Foundation

/// Read-only evidence about the system route directory and the raw aggregate.
/// Matching members does not verify playback or system reconnection after Quit.
struct SystemRouteMemberComparison: Sendable, Equatable {
    enum Comparison: String, Sendable {
        case matches, mismatch, unknown
    }

    let systemContextMemberIDs: [String]?
    let rawAggregateMemberIDs: [String]?
    let readbackStable: Bool
    let selectedForComparison: Bool

    init?(snapshot: [String: Any]) {
        guard let decoded = PrivateRouteSnapshotAdapter.memberComparison(snapshot) else { return nil }
        self = decoded
    }

    init(systemContextMemberIDs: [String]?, rawAggregateMemberIDs: [String]?,
         readbackStable: Bool, selectedForComparison: Bool) {
        self.systemContextMemberIDs = systemContextMemberIDs
        self.rawAggregateMemberIDs = rawAggregateMemberIDs
        self.readbackStable = readbackStable
        self.selectedForComparison = selectedForComparison
    }

    var comparison: Comparison {
        guard selectedForComparison, readbackStable,
              let system = validated(systemContextMemberIDs),
              let raw = validated(rawAggregateMemberIDs) else { return .unknown }
        return system == raw ? .matches : .mismatch
    }

    func confirmsSelectedReceiver(_ identifier: String) -> Bool {
        comparison == .matches && !identifier.isEmpty && rawAggregateMemberIDs == [identifier]
    }

    var diagnosticFields: [String: Any] {
        ["systemContextMemberIDs": systemContextMemberIDs as Any? ?? NSNull(),
         "rawAggregateMemberIDs": rawAggregateMemberIDs as Any? ?? NSNull(),
         "readbackStable": readbackStable, "selectedForComparison": selectedForComparison,
         "comparison": comparison.rawValue]
    }

    private func validated(_ identifiers: [String]?) -> [String]? {
        guard let identifiers, identifiers.allSatisfy({ !$0.isEmpty }),
              Set(identifiers).count == identifiers.count else { return nil }
        return identifiers.sorted()
    }
}
