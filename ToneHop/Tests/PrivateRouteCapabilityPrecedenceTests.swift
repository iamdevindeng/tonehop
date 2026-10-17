import Foundation
import XCTest
@testable import ToneHop

/// Raw evidence fixtures intentionally compile before the M4 decoder changes.
/// The positive test must fail against the M1 merger, establishing the behavior
/// change without running discovery or any native output request.
final class PrivateRouteCapabilityPrecedenceTests: XCTestCase {
    private let receiver = "bedroom"
    private let aggregate = "12345678-abcd-4abc-8def-123456789abc"
    private var stream: String { "\(aggregate)-100-Audio" }

    func testVerifiedWrapperIdentityAndCurrentRetainedDescriptorPreserveCapabilityDespiteAVContextDenial() {
        for uid: Any in [NSNull(), stream] {
            let snapshot = merge(retained: retained(uid: uid))
            XCTAssertEqual(snapshot.routes.count, 1)
            XCTAssertEqual(snapshot.routes.first?.identifier, receiver)
            XCTAssertEqual(snapshot.routes.first?.name, "AV Bedroom", "The capability repair does not change the discovered name.")
            XCTAssertEqual(snapshot.routes.first?.transportKind, .airplay)
            XCTAssertEqual(snapshot.routes.first?.selectionCapability, .retainedAirPlay)
            XCTAssertEqual(snapshot.routes.first?.uid, uid as? String)
            XCTAssertEqual(snapshot.routes.first?.isSelected, false)
        }
    }

    func testSameStringsAndAirPlayClassificationWithoutWrapperMappingDoNotGrantCapability() {
        var endpoint = endpoint()
        endpoint.removeValue(forKey: "avIdentity")
        assertUnavailable(merge(endpoint: endpoint))
        endpoint = self.endpoint()
        endpoint.removeValue(forKey: "deviceEligibility")
        assertUnavailable(merge(endpoint: endpoint))
        var av = av()
        av.removeValue(forKey: "selectionEvidence")
        assertUnavailable(merge(av: av))
    }

    func testExplicitDeviceRestrictionsOnEitherSourceCannotBeOverridden() {
        for (key, denied): (String, Bool) in [("supportsAudio", false), ("isCached", true),
                                            ("isDeviceDisabled", true), ("requiresAuthorization", true)] {
            var eligibility = eligible()
            eligibility[key] = denied
            var av = self.av()
            var evidence = av["selectionEvidence"] as! [String: Any]
            evidence["deviceEligibility"] = eligibility
            av["selectionEvidence"] = evidence
            assertUnavailable(merge(av: av), key)
            var endpoint = self.endpoint()
            endpoint["deviceEligibility"] = eligibility
            assertUnavailable(merge(endpoint: endpoint), key)
        }
    }

    func testMissingNullOrNonBooleanEligibilityNeverMeansAllowed() {
        for key in ["supportsAudio", "isCached", "isDeviceDisabled", "requiresAuthorization"] {
            for malformed: Any? in [nil, NSNull(), "false", NSNumber(value: 0), NSNumber(value: 1)] {
                var eligibility = eligible()
                if let malformed { eligibility[key] = malformed }
                else { eligibility.removeValue(forKey: key) }
                var av = self.av()
                var evidence = av["selectionEvidence"] as! [String: Any]
                evidence["deviceEligibility"] = eligibility
                av["selectionEvidence"] = evidence
                assertUnavailable(merge(av: av), key)
                var endpoint = self.endpoint()
                endpoint["deviceEligibility"] = eligibility
                assertUnavailable(merge(endpoint: endpoint), key)
            }
        }
    }

    func testContextAndUniquenessEvidenceMustExplainTheAVDenialExactly() {
        for (key, values): (String, [Any?]) in [
            ("contextWritable", [true, nil, NSNull(), "false", NSNumber(value: 0)]),
            ("identityUnique", [false, nil, NSNull(), "true", NSNumber(value: 1)]),
        ] {
            for value in values {
                var av = self.av()
                var evidence = av["selectionEvidence"] as! [String: Any]
                if let value { evidence[key] = value }
                else { evidence.removeValue(forKey: key) }
                av["selectionEvidence"] = evidence
                assertUnavailable(merge(av: av), key)
            }
        }
    }

    func testMalformedAVSelectionFlagsAndUIDCannotBeTreatedAsAbsentCapability() {
        for key in ["canSelect", "isSelected"] {
            for value: Any? in [nil, NSNull(), "false", NSNumber(value: 0)] {
                var av = self.av()
                if let value { av[key] = value }
                else { av.removeValue(forKey: key) }
                assertUnavailable(merge(av: av), key)
            }
        }
        var av = self.av()
        av["uid"] = 42
        assertUnavailable(merge(av: av))
    }

    func testMappingMustBeStableNonemptyTypedAndMatchBothIdentifierDomains() {
        for key in ["endpointIdentifier", "avDeviceIdentifier"] {
            for value: Any? in [nil, NSNull(), "", "other-receiver", 42] {
                var endpoint = self.endpoint()
                var identity = endpoint["avIdentity"] as! [String: Any]
                if let value { identity[key] = value }
                else { identity.removeValue(forKey: key) }
                endpoint["avIdentity"] = identity
                assertUnavailable(merge(endpoint: endpoint), key)
            }
        }
        for value: Any? in [nil, NSNull(), false, "true", NSNumber(value: 1)] {
            var endpoint = self.endpoint()
            var identity = endpoint["avIdentity"] as! [String: Any]
            if let value { identity["readbackStable"] = value }
            else { identity.removeValue(forKey: "readbackStable") }
            endpoint["avIdentity"] = identity
            assertUnavailable(merge(endpoint: endpoint))
        }
    }

    func testDuplicateAVOrEndpointIdentityRemainsUnavailable() {
        let av = self.av()
        let endpoint = self.endpoint()
        let a = compose(av: ["routes": [av, av]], endpoints: ["endpoints": [endpoint]], retained: retained())
        XCTAssertTrue(a.routes.allSatisfy { $0.selectionCapability == .unavailable })
        let b = compose(av: ["routes": [av]], endpoints: ["endpoints": [endpoint, endpoint]], retained: retained())
        assertUnavailable(b)
        XCTAssertNotNil(b.warning)
    }

    func testFilteredCachedRestrictedOrMalformedEndpointCannotHideAnIdentityConflict() {
        for variant: [String: Any] in [["wrapperIsCached": true], ["name": 42], ["deviceFeatures": NSNull()],
                                       ["isRemoteControlOnly": true], ["isDeviceDisabled": true]] {
            var conflicting = endpoint()
            conflicting.merge(variant) { _, new in new }
            assertUnavailable(compose(av: ["routes": [av()]],
                                      endpoints: ["endpoints": [endpoint(), conflicting]], retained: retained()))
        }
    }

    func testEarlierEndpointRestrictionOrMalformedFlagCannotBeErasedByLaterEligibleWrapperRead() {
        for key in ["isRemoteControlOnly", "wrapperIsCached", "isDeviceDisabled", "requiresAuthorization"] {
            for value: Any? in [nil, NSNull(), true, "false", NSNumber(value: 0)] {
                var endpoint = self.endpoint()
                if let value { endpoint[key] = value }
                else { endpoint.removeValue(forKey: key) }
                assertUnavailable(merge(endpoint: endpoint), key)
            }
        }
        var endpoint = self.endpoint()
        endpoint["deviceFeatures"] = true
        assertUnavailable(merge(endpoint: endpoint))
    }

    func testUnavailableRawCacheDiagnosticDoesNotHideVerifiedRetainedCapability() {
        for value: Any? in [nil, NSNull(), "false", NSNumber(value: 0), NSNumber(value: 1)] {
            var endpoint = self.endpoint()
            if let value { endpoint["isCached"] = value }
            else { endpoint.removeValue(forKey: "isCached") }
            endpoint["propertyStatus"] = ["isCached": ["state": "readFailed", "status": -12784]]
            let snapshot = compose(av: ["routes": [av()]],
                endpoints: ["endpoints": [endpoint], "incompleteDeviceCount": 0,
                            "diagnostics": ["fieldIssues": [["field": "isCached", "state": "readFailed", "status": -12784]]]],
                retained: retained())
            XCTAssertEqual(snapshot.sourceHealth?.endpointDiscovery, .succeeded)
            XCTAssertNil(snapshot.warning)
            XCTAssertEqual(snapshot.routes.first?.selectionCapability, .retainedAirPlay)
            XCTAssertEqual(snapshot.routes.first?.isSelected, false)
            XCTAssertTrue(snapshot.diagnostics.contains("isCached"))
            XCTAssertTrue(snapshot.diagnostics.contains("-12784"))
        }
    }

    func testExplicitRawCacheRestrictionStillPreventsCapabilitySupplement() {
        var endpoint = self.endpoint()
        endpoint["isCached"] = true
        assertUnavailable(merge(endpoint: endpoint))
    }

    func testUnknownReceiverEvidenceStillWarnsAndPreventsCapabilitySupplement() {
        for excluded: [String: Any] in [[:], ["wrapperIsCached": true], ["isRemoteControlOnly": true], ["deviceFeatures": 0]] {
            let unidentified = ["name": "Unidentified receiver"].merging(excluded) { _, value in value }
            let snapshot = compose(av: ["routes": [av()]],
                endpoints: ["endpoints": [endpoint(), unidentified], "incompleteDeviceCount": 1],
                retained: retained())
            XCTAssertEqual(snapshot.sourceHealth?.endpointDiscovery, .partial)
            XCTAssertTrue(snapshot.warning?.contains(expectedLocalized("receiver discovery", "接收器发现")) == true)
            assertUnavailable(snapshot, "Unknown identity can hide a duplicate even on an excluded row.")
        }
    }

    func testBareOrStaleRetainedCapabilityCannotUpgradeTheAVRow() {
        assertUnavailable(merge(retained: ["retained": ["identifier": receiver, "canSelect": true]]))
        for variant: [String: Any] in [["canSelect": false], ["state": "invalid"], ["isSelected": true], ["associatedUID": NSNull()]] {
            var raw = retained(uid: stream)
            var capability = raw["retained"] as! [String: Any]
            capability.merge(variant) { _, new in new }
            raw["retained"] = capability
            assertUnavailable(merge(retained: raw))
        }
        var raw = retained()
        var capability = raw["retained"] as! [String: Any]
        var descriptor = capability["catalogRoute"] as! [String: Any]
        descriptor["readbackStable"] = false
        capability["catalogRoute"] = descriptor
        raw["retained"] = capability
        assertUnavailable(merge(retained: raw))
    }

    func testNonBooleanRetainedAndReadbackFlagsCannotGrantTheNewCapability() {
        for key in ["canSelect", "isSelected", "readbackStable"] {
            var raw = retained()
            var capability = raw["retained"] as! [String: Any]
            if key == "readbackStable" {
                var descriptor = capability["catalogRoute"] as! [String: Any]
                descriptor[key] = NSNumber(value: 1)
                capability["catalogRoute"] = descriptor
            } else {
                capability[key] = NSNumber(value: key == "canSelect" ? 1 : 0)
            }
            raw["retained"] = capability
            assertUnavailable(merge(retained: raw), key)
        }
    }

    func testExplicitAVUIDCannotBeReplacedByDifferentOrVerifiedEmptyRetainedUID() {
        for retainedUID: Any in [NSNull(), stream] {
            var av = self.av()
            av["uid"] = "conflicting-stream"
            assertUnavailable(merge(av: av, retained: retained(uid: retainedUID)))
        }
        var matching = av()
        matching["uid"] = stream
        XCTAssertEqual(merge(av: matching, retained: retained(uid: stream)).routes.first?.selectionCapability, .retainedAirPlay)
    }

    func testUIDOwnedByAnotherRouteOrContradictoryStreamAssociationPreventsUpgrade() {
        var other = av()
        other["identifier"] = "other"
        other["uid"] = stream
        let snapshot = compose(av: ["routes": [av(), other]], endpoints: ["endpoints": [endpoint()]], retained: retained(uid: stream))
        XCTAssertEqual(snapshot.routes.first { $0.identifier == receiver }?.selectionCapability, .unavailable)
        var raw = retained(uid: stream)
        raw["existingStreamAssociation"] = ["identifier": receiver, "uid": "\(aggregate)-101-Audio",
            "aggregateIdentifier": aggregate, "contextIdentifier": "context", "readbackStable": true]
        assertUnavailable(merge(retained: raw))
        for associatedUID in [stream, "\(aggregate)-102-Audio"] {
            raw["existingStreamAssociation"] = ["identifier": "different-receiver", "uid": associatedUID,
                "aggregateIdentifier": aggregate, "contextIdentifier": "context", "readbackStable": true]
            assertUnavailable(merge(retained: raw))
        }
    }

    func testSelectedEvidencePreventsAnUnselectedDescriptorFromAddingANewCapability() {
        var av = self.av()
        av["isSelected"] = true
        assertUnavailable(merge(av: av))
        let other: [String: Any] = ["selection": ["identifier": "other", "name": "Other", "uid": "other-stream",
            "aggregateIdentifier": aggregate, "contextIdentifier": "context", "aggregateContextIdentifier": "context",
            "associatedUID": "other-stream", "halUID": "other-stream", "audioStreamUIDs": ["other-stream"],
            "memberIdentifiers": ["other"], "readbackStable": true]]
        let snapshot = compose(av: ["routes": [self.av()]], endpoints: ["endpoints": [endpoint()]],
                               selection: other, retained: retained())
        XCTAssertEqual(snapshot.routes.first { $0.identifier == receiver }?.selectionCapability, .unavailable)
        XCTAssertEqual(snapshot.routes.filter(\.isSelected).map(\.identifier), ["other"])
    }

    func testUnconfirmedAVSelectionCannotIntroduceAnotherUndiscoveredRetainedReceiver() {
        let claim: [String: Any] = ["identifier": "other", "name": "Other", "transport": "unknown", "isSelected": true]
        let snapshot = compose(av: ["routes": [claim]], endpoints: [:], retained: retained())
        XCTAssertEqual(snapshot.routes.map(\.identifier), ["other"])
        XCTAssertTrue(snapshot.routes.allSatisfy { !$0.isSelected },
                      "The AV claim constrains capability without becoming formal selected evidence.")

        let withoutClaim = compose(av: ["routes": [["identifier": "other", "name": "Other", "isSelected": false]]],
                                   endpoints: [:], retained: retained())
        XCTAssertEqual(withoutClaim.routes.first { $0.identifier == receiver }?.selectionCapability, .retainedAirPlay)
    }

    func testFailedSupportingReadDoesNotUpgradeTheExistingUnknownAVRow() {
        let av = PrivateRouteSnapshotAdapter.avDiscovery(["routes": [self.av()]])
        let endpoints = PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [endpoint()], "incompleteDeviceCount": 0])
        let selection = PrivateRouteSnapshotAdapter.systemSelection(unselected())
        let held = PrivateRouteSnapshotAdapter.retainedSystemRoute(retained())
        let failure = NSError(domain: "fixture", code: 1)
        assertUnavailable(PrivateRouteCatalog.merge(av: av, endpoints: .failed(failure), selection: selection, retained: held))
        assertUnavailable(PrivateRouteCatalog.merge(av: av, endpoints: endpoints, selection: .failed(failure), retained: held))
        assertUnavailable(PrivateRouteCatalog.merge(av: av, endpoints: endpoints, selection: selection, retained: .failed(failure)))
    }

    func testExistingValidatedAVSelectionAndEndpointOnlyPathsKeepTheirCapabilities() {
        var av = self.av()
        av["canSelect"] = true
        XCTAssertEqual(merge(av: av).routes.first?.selectionCapability, .avSystemRoute)
        let withoutAV = compose(av: [:], endpoints: ["endpoints": [endpoint()]], retained: retained())
        XCTAssertEqual(withoutAV.routes.first?.selectionCapability, .retainedAirPlay)
    }

    func testUnknownOrFailedSystemSelectionIsNotAConfirmedUnselectedAggregate() {
        for selection: [String: Any] in [[:], ["selection": NSNull()],
            ["selection": NSNull(), "isUnselectedConfirmed": false],
            ["selection": NSNull(), "isUnselectedConfirmed": NSNull()],
            ["selection": NSNull(), "isUnselectedConfirmed": NSNumber(value: 1)],
            ["selection": NSNull(), "isUnselectedConfirmed": "true"],
            ["selection": ["readbackStable": false], "isUnselectedConfirmed": true],
            ["isUnselectedConfirmed": true],
        ] {
            assertUnavailable(compose(av: ["routes": [av()]], endpoints: ["endpoints": [endpoint()]],
                                      selection: selection, retained: retained()))
        }
    }

    private func assertUnavailable(_ snapshot: PrivateRouteSnapshot, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.routes.first { $0.identifier == receiver }?.selectionCapability, .unavailable, message, file: file, line: line)
    }

    private func eligible() -> [String: Any] {
        ["supportsAudio": true, "isCached": false, "isDeviceDisabled": false, "requiresAuthorization": false]
    }

    private func av() -> [String: Any] {
        ["identifier": receiver, "name": "AV Bedroom", "transport": "unknown", "canSelect": false, "isSelected": false,
         "selectionEvidence": ["contextWritable": false, "identityUnique": true, "deviceEligibility": eligible()]]
    }

    private func endpoint() -> [String: Any] {
        ["identifier": receiver, "name": "Endpoint Bedroom", "deviceFeatures": 1,
         "isRemoteControlOnly": false, "isCached": false, "wrapperIsCached": false,
         "isDeviceDisabled": false, "requiresAuthorization": false, "deviceEligibility": eligible(),
         "avIdentity": ["endpointIdentifier": receiver, "avDeviceIdentifier": receiver, "readbackStable": true]]
    }

    private func retained(uid: Any = NSNull()) -> [String: Any] {
        ["sessionReadSucceeded": true, "retained": ["identifier": receiver, "canSelect": true, "associatedUID": uid,
                      "associationReadbackStable": uid is String, "state": "retained", "isSelected": false,
                      "catalogRoute": ["identifier": receiver, "name": "Held Bedroom", "transport": "airplay", "uid": uid, "readbackStable": true]]]
    }

    private func merge(av: [String: Any]? = nil, endpoint: [String: Any]? = nil,
                       retained: [String: Any]? = nil) -> PrivateRouteSnapshot {
        compose(av: ["routes": [av ?? self.av()]], endpoints: ["endpoints": [endpoint ?? self.endpoint()]],
                retained: retained ?? self.retained())
    }

    private func unselected() -> [String: Any] {
        ["selection": NSNull(), "isUnselectedConfirmed": true]
    }

    private func compose(av: [String: Any], endpoints: [String: Any], selection: [String: Any]? = nil,
                         retained: [String: Any]) -> PrivateRouteSnapshot {
        let endpointSnapshot: [String: Any] = ["endpoints": [], "incompleteDeviceCount": 0].merging(endpoints) { _, value in value }
        let retainedSnapshot: [String: Any] = ["sessionReadSucceeded": true].merging(retained) { _, value in value }
        return PrivateRouteCatalog.merge(av: PrivateRouteSnapshotAdapter.avDiscovery(av),
                                  endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(endpointSnapshot),
                                  selection: PrivateRouteSnapshotAdapter.systemSelection(selection ?? unselected()),
                                  retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(retainedSnapshot))
    }
}
