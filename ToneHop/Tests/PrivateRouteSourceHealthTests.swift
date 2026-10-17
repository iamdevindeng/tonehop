import Foundation
import XCTest
@testable import ToneHop

final class PrivateRouteSourceHealthTests: XCTestCase {
    func testHealthyUncapturedRetainedSessionIsNotAReadFailure() {
        let evidence = PrivateRouteSnapshotAdapter.retainedSystemRoute([
            "sessionReadSucceeded": true, "retained": NSNull(),
        ])
        XCTAssertEqual(evidence.outcome, .succeeded)
        XCTAssertNil(evidence.capability)
        XCTAssertNil(evidence.existingStreamAssociation)
        XCTAssertNil(catalog(retained: evidence).warning)
    }

    func testFailedRetainedSessionCannotPublishOtherwiseValidCapabilityOrAssociation() {
        var snapshot = retainedSnapshot()
        let healthy = PrivateRouteSnapshotAdapter.retainedSystemRoute(snapshot)
        XCTAssertEqual(healthy.outcome, .succeeded)
        XCTAssertNotNil(healthy.capability)
        XCTAssertNotNil(healthy.existingStreamAssociation)
        XCTAssertNotNil(healthy.memberComparison)
        snapshot["sessionReadSucceeded"] = false
        let evidence = PrivateRouteSnapshotAdapter.retainedSystemRoute(snapshot)

        XCTAssertEqual(evidence.outcome, .failed)
        XCTAssertNil(evidence.capability)
        XCTAssertNil(evidence.verifiedUnselectedDescriptor)
        XCTAssertNil(evidence.existingStreamAssociation)
        XCTAssertNil(evidence.memberComparison)
        let result = catalog(retained: evidence)
        XCTAssertTrue(result.routes.isEmpty)
        XCTAssertEqual(result.sourceHealth?.retainedRoute, .failed)
        XCTAssertTrue(result.warning?.contains(expectedLocalized("receiver switching capability", "接收器切换能力")) == true)
    }

    func testMissingOrMalformedRetainedHealthCannotCountAsSuccessfulRead() {
        for flag: Any? in [nil, NSNull(), false, "true", NSNumber(value: 1)] {
            var snapshot = retainedSnapshot()
            if let flag { snapshot["sessionReadSucceeded"] = flag }
            else { snapshot.removeValue(forKey: "sessionReadSucceeded") }
            let evidence = PrivateRouteSnapshotAdapter.retainedSystemRoute(snapshot)
            XCTAssertEqual(evidence.outcome, .failed)
            XCTAssertNil(evidence.capability)
            XCTAssertNil(evidence.existingStreamAssociation)
        }
    }

    func testRetainedHealthUsesExplicitFlagInsteadOfDiagnosticStateNames() {
        let healthy = PrivateRouteSnapshotAdapter.retainedSystemRoute([
            "sessionReadSucceeded": true, "retained": NSNull(), "diagnostics": ["state": "readFailed"],
        ])
        XCTAssertEqual(healthy.outcome, .succeeded)

        let failed = PrivateRouteSnapshotAdapter.retainedSystemRoute([
            "sessionReadSucceeded": false, "diagnostics": ["state": "retained", "recoveryState": "healthy"],
        ])
        XCTAssertEqual(failed.outcome, .failed)
    }

    func testRetainedRecoveryClearsItsWarningWithoutRequiringACapturedReceiver() {
        let failed = catalog(retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": false]))
        XCTAssertNotNil(failed.warning)
        let recovered = catalog(retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true]))
        XCTAssertNil(recovered.warning)
        XCTAssertTrue(recovered.routes.isEmpty)
        XCTAssertEqual(recovered.sourceHealth?.retainedRoute, .succeeded)
    }

    func testIncompleteEndpointReadKeepsHealthyRowsAndPublishesPartialHealth() {
        let evidence = PrivateRouteSnapshotAdapter.endpointDiscovery([
            "endpoints": [endpoint(), ["identifier": "unreadable", "name": "Incomplete", "deviceFeatures": NSNull()]],
            "incompleteDeviceCount": 1,
        ])
        XCTAssertEqual(evidence.outcome, .partial)
        XCTAssertEqual(evidence.routes.map(\.identifier), ["receiver"])
        let result = catalog(endpoints: evidence)
        XCTAssertEqual(result.routes.map(\.identifier), ["receiver"])
        XCTAssertEqual(result.sourceHealth?.endpointDiscovery, .partial)
        XCTAssertTrue(result.warning?.contains(expectedLocalized("information is incomplete (receiver discovery)", "读取不完整（接收器发现）")) == true)
    }

    func testMissingMalformedOrFractionalCompletenessCannotSilentlyClaimHealthyEndpoints() {
        for count: Any? in [nil, NSNull(), false, true, "0", -1, 0.5] {
            var snapshot: [String: Any] = ["endpoints": [endpoint()]]
            if let count { snapshot["incompleteDeviceCount"] = count }
            let evidence = PrivateRouteSnapshotAdapter.endpointDiscovery(snapshot)
            XCTAssertEqual(evidence.outcome, .partial)
            XCTAssertEqual(evidence.routes.map(\.identifier), ["receiver"])
            XCTAssertNotNil(catalog(endpoints: evidence).warning)
        }
    }

    func testMalformedEndpointDirectoryCannotClaimSuccessfulEmptyRead() {
        for directory: Any? in [nil, NSNull(), "empty", 0] {
            var snapshot: [String: Any] = ["incompleteDeviceCount": 0]
            if let directory { snapshot["endpoints"] = directory }
            let evidence = PrivateRouteSnapshotAdapter.endpointDiscovery(snapshot)
            XCTAssertEqual(evidence.outcome, .failed)
            XCTAssertTrue(evidence.routes.isEmpty)
            XCTAssertTrue(catalog(endpoints: evidence).warning?.contains(expectedLocalized("receiver discovery", "接收器发现")) == true)
        }
    }

    func testExplicitlyCompleteEmptyEndpointReadIsHealthyAndClearsPartialWarning() {
        let partial = catalog(endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery([
            "endpoints": [], "incompleteDeviceCount": 1,
        ]))
        XCTAssertNotNil(partial.warning)
        let recovered = catalog(endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery([
            "endpoints": [], "incompleteDeviceCount": 0, "diagnostics": ["state": "readFailed"],
        ]))
        XCTAssertNil(recovered.warning)
        XCTAssertEqual(recovered.sourceHealth?.endpointDiscovery, .succeeded)
    }

    func testPartialAndFailedSourcesBothRemainVisible() {
        let result = catalog(
            endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [endpoint()], "incompleteDeviceCount": 1]),
            retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": false]))
        XCTAssertTrue(result.warning?.contains(expectedLocalized("could not be read (receiver switching capability)", "读取失败（接收器切换能力）")) == true)
        XCTAssertTrue(result.warning?.contains(expectedLocalized("information is incomplete (receiver discovery)", "读取不完整（接收器发现）")) == true)
        XCTAssertEqual(result.routes.map(\.identifier), ["receiver"])
    }

    private func catalog(endpoints: EndpointDiscoveryEvidence? = nil,
                         retained: RetainedSystemRouteEvidence? = nil) -> PrivateRouteSnapshot {
        PrivateRouteCatalog.merge(
            av: PrivateRouteSnapshotAdapter.avDiscovery(["routes": []]),
            endpoints: endpoints ?? PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [], "incompleteDeviceCount": 0]),
            selection: PrivateRouteSnapshotAdapter.systemSelection(["selection": NSNull(), "isUnselectedConfirmed": true]),
            retained: retained ?? PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true]))
    }

    private func endpoint() -> [String: Any] {
        ["identifier": "receiver", "name": "Receiver", "deviceFeatures": 1,
         "isRemoteControlOnly": false, "wrapperIsCached": false]
    }

    private func retainedSnapshot() -> [String: Any] {
        let aggregate = "12345678-abcd-4abc-8def-123456789abc"
        let uid = "\(aggregate)-100-Audio"
        return ["sessionReadSucceeded": true,
                "retained": ["identifier": "receiver", "name": "Receiver", "canSelect": true,
                    "associatedUID": uid, "associationReadbackStable": true, "state": "retained", "isSelected": false,
                    "catalogRoute": ["identifier": "receiver", "name": "Receiver", "transport": "airplay",
                                     "uid": uid, "readbackStable": true]],
                "existingStreamAssociation": ["identifier": "receiver", "uid": uid, "aggregateIdentifier": aggregate,
                                               "contextIdentifier": "context", "readbackStable": true],
                "diagnostics": ["systemRouteMemberComparison": ["systemContextMemberIDs": ["receiver"],
                    "rawAggregateMemberIDs": ["receiver"], "readbackStable": true, "selectedForComparison": true]]]
    }
}
