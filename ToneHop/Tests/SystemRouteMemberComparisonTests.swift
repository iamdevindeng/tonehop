import XCTest
@testable import ToneHop

final class SystemRouteMemberComparisonTests: XCTestCase {
    func testRawAddedMemberWithEmptySystemDirectoryIsMismatchDespiteStableReadback() {
        let evidence = comparison(system: [], raw: ["bedroom"])
        XCTAssertEqual(evidence?.comparison, .mismatch)
        XCTAssertFalse(evidence?.confirmsSelectedReceiver("bedroom") == true)
    }

    func testExactSelectedReceiverAgreementPassesOnlyMemberCheck() {
        let evidence = comparison(system: ["bedroom"], raw: ["bedroom"])
        XCTAssertEqual(evidence?.comparison, .matches)
        XCTAssertTrue(evidence?.confirmsSelectedReceiver("bedroom") == true)
        XCTAssertFalse(evidence?.confirmsSelectedReceiver("other") == true)
        XCTAssertEqual(evidence?.diagnosticFields["comparison"] as? String, "matches")
    }

    func testLocalOutputWithSurvivingRawMemberIsNotComparedAsSelectedRoute() {
        for raw in [[], ["bedroom"]] {
            let evidence = comparison(system: [], raw: raw, selected: false)
            XCTAssertEqual(evidence?.comparison, .unknown)
            XCTAssertFalse(evidence?.confirmsSelectedReceiver("bedroom") == true)
        }
    }

    func testOrderDoesNotMatterButExtraOrDifferentMembersDo() {
        XCTAssertEqual(comparison(system: ["office", "bedroom"], raw: ["bedroom", "office"])?.comparison, .matches)
        XCTAssertEqual(comparison(system: ["office"], raw: ["bedroom"])?.comparison, .mismatch)
        XCTAssertEqual(comparison(system: ["office", "bedroom"], raw: ["bedroom"])?.comparison, .mismatch)
        XCTAssertFalse(comparison(system: ["office", "bedroom"], raw: ["bedroom", "office"])?.confirmsSelectedReceiver("bedroom") == true)
    }

    func testMissingOrUnstableReadbackCannotPassEvenWhenNativeLabelClaimsMatch() {
        XCTAssertNil(SystemRouteMemberComparison(snapshot: [:]))
        for changes: [String: Any] in [
            ["readbackStable": false], ["readbackStable": NSNull()],
            ["selectedForComparison": false], ["selectedForComparison": NSNull()],
            ["systemContextMemberIDs": NSNull()], ["rawAggregateMemberIDs": NSNull()],
            ["systemContextMemberIDs": [1]], ["rawAggregateMemberIDs": "bedroom"],
        ] {
            var fields: [String: Any] = ["systemContextMemberIDs": ["bedroom"],
                                         "rawAggregateMemberIDs": ["bedroom"],
                                         "readbackStable": true, "selectedForComparison": true,
                                         "comparison": "matches"]
            fields.merge(changes) { _, new in new }
            let evidence = SystemRouteMemberComparison(snapshot: ["diagnostics": ["systemRouteMemberComparison": fields]])
            XCTAssertEqual(evidence?.comparison, .unknown)
            XCTAssertFalse(evidence?.confirmsSelectedReceiver("bedroom") == true)
        }
    }

    func testDuplicateAndEmptyIdentitiesAreUnknownRatherThanSetEqualitySuccess() {
        for members in [["bedroom", "bedroom"], [""], ["bedroom", ""]] {
            let evidence = comparison(system: members, raw: members)
            XCTAssertEqual(evidence?.comparison, .unknown)
            XCTAssertFalse(evidence?.confirmsSelectedReceiver("bedroom") == true)
        }
    }

    private func comparison(system: [String], raw: [String], selected: Bool = true) -> SystemRouteMemberComparison? {
        SystemRouteMemberComparison(snapshot: ["diagnostics": ["systemRouteMemberComparison": [
            "systemContextMemberIDs": system, "rawAggregateMemberIDs": raw, "readbackStable": true,
            "selectedForComparison": selected,
        ]]])
    }
}
