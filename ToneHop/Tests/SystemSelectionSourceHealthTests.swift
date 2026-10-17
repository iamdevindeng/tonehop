import Foundation
import XCTest
@testable import ToneHop

final class SystemSelectionSourceHealthTests: XCTestCase {
    private var selected: [String: Any] {
        ["identifier": "receiver", "name": "Receiver", "uid": "stream",
         "aggregateIdentifier": "aggregate", "contextIdentifier": "context",
         "aggregateContextIdentifier": "context", "associatedUID": "stream",
         "halUID": "stream", "audioStreamUIDs": ["stream"],
         "memberIdentifiers": ["receiver"], "readbackStable": true]
    }

    private var unselected: [String: Any] {
        ["selection": NSNull(), "isUnselectedConfirmed": true]
    }

    func testVerifiedSelectionIsHealthyWithoutGrantingSwitchCapability() {
        let evidence = PrivateRouteSnapshotAdapter.systemSelection(["selection": selected])
        XCTAssertEqual(evidence.outcome, .succeeded)
        XCTAssertEqual(evidence.route?.identifier, "receiver")
        XCTAssertEqual(evidence.route?.uid, "stream")
        XCTAssertEqual(evidence.route?.canSelect, false)
        XCTAssertFalse(evidence.confirmsUnselectedAggregate)
    }

    func testExplicitlyConfirmedEmptySelectionIsHealthy() {
        let evidence = PrivateRouteSnapshotAdapter.systemSelection(unselected)
        XCTAssertEqual(evidence.outcome, .succeeded)
        XCTAssertNil(evidence.route)
        XCTAssertTrue(evidence.confirmsUnselectedAggregate)
    }

    func testReturnedFailureDictionaryDoesNotCountAsHealthyRead() {
        let evidence = PrivateRouteSnapshotAdapter.systemSelection([
            "selection": NSNull(), "isUnselectedConfirmed": false,
            "diagnostics": ["state": "contextUnavailable", "contextStatus": -1],
        ])
        XCTAssertEqual(evidence.outcome, .failed)
        XCTAssertNil(evidence.route)
        XCTAssertFalse(evidence.confirmsUnselectedAggregate)
    }

    func testMissingMalformedAndUnconfirmedEvidenceCannotClaimHealthyEmpty() {
        let snapshots: [[String: Any]] = [
            [:], ["selection": NSNull()], ["isUnselectedConfirmed": true],
            ["selection": NSNull(), "isUnselectedConfirmed": NSNull()],
            ["selection": NSNull(), "isUnselectedConfirmed": NSNumber(value: 1)],
            ["selection": NSNull(), "isUnselectedConfirmed": "true"],
            ["selection": ["readbackStable": false], "isUnselectedConfirmed": true],
        ]
        for snapshot in snapshots {
            let evidence = PrivateRouteSnapshotAdapter.systemSelection(snapshot)
            XCTAssertEqual(evidence.outcome, .failed, "\(snapshot)")
            XCTAssertNil(evidence.route)
            XCTAssertFalse(evidence.confirmsUnselectedAggregate)
        }
    }

    func testConflictingIdentityDoesNotBecomeHealthyOrUnselected() {
        for field in ["associatedUID", "halUID", "aggregateContextIdentifier"] {
            var payload = selected
            payload[field] = "different-identity"
            let evidence = PrivateRouteSnapshotAdapter.systemSelection([
                "selection": payload, "isUnselectedConfirmed": true,
            ])
            XCTAssertEqual(evidence.outcome, .failed, field)
            XCTAssertNil(evidence.route)
            XCTAssertFalse(evidence.confirmsUnselectedAggregate)
        }
    }

    func testHealthUsesStructuredEvidenceInsteadOfDiagnosticWording() {
        var healthy = unselected
        healthy["diagnostics"] = ["state": "readFailed"]
        XCTAssertEqual(PrivateRouteSnapshotAdapter.systemSelection(healthy).outcome, .succeeded)

        let unknown: [String: Any] = ["selection": NSNull(), "isUnselectedConfirmed": false,
                                     "diagnostics": ["state": "verifiedSelectedAggregate"]]
        XCTAssertEqual(PrivateRouteSnapshotAdapter.systemSelection(unknown).outcome, .failed)
    }

    func testUnconfirmedReadPublishesWarningAndConfirmedRecoveryClearsIt() {
        let failed = catalog(["selection": NSNull(), "isUnselectedConfirmed": false])
        XCTAssertEqual(failed.sourceHealth?.systemSelection, .failed)
        XCTAssertTrue(failed.warning?.contains(expectedLocalized("current receiver confirmation", "当前接收器确认")) == true)
        XCTAssertTrue(failed.routes.isEmpty)

        let recovered = catalog(unselected)
        XCTAssertEqual(recovered.sourceHealth?.systemSelection, .succeeded)
        XCTAssertNil(recovered.warning)
        XCTAssertTrue(recovered.routes.isEmpty)
    }

    private func catalog(_ selection: [String: Any]) -> PrivateRouteSnapshot {
        PrivateRouteCatalog.merge(
            av: PrivateRouteSnapshotAdapter.avDiscovery(["routes": []]),
            endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [], "incompleteDeviceCount": 0]),
            selection: PrivateRouteSnapshotAdapter.systemSelection(selection),
            retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true]))
    }
}
