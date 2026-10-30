import Foundation
import XCTest
@testable import ToneHop

/// Exercises the production value adapter and complete catalog path. Native
/// recovery submission and strict selected readback are covered separately by
/// the bridge's injected-runtime tests; these tests perform no audio writes.
final class ExistingSystemStreamRecoveryEvidenceTests: XCTestCase {
    private let receiver = "bedroom"
    private let aggregate = "12345678-abcd-4abc-8def-123456789abc"
    private var uid: String { "\(aggregate)-100-Audio" }

    func testExistingStreamRecoverySupportsOnlyMacOS27RegardlessOfMinorOrPatchVersion() {
        let cases: [(major: Int, minor: Int, patch: Int, supported: Bool)] = [
            (27, 0, 0, true),
            (27, 0, 1, true),
            (27, 1, 0, true),
            (27, 3, 2, true),
            (26, 9, 9, false),
            (28, 0, 0, false)
        ]
        for testCase in cases {
            let version = OperatingSystemVersion(
                majorVersion: testCase.major,
                minorVersion: testCase.minor,
                patchVersion: testCase.patch
            )
            XCTAssertEqual(
                THRExistingStreamRecoverySupportedOS(version),
                testCase.supported,
                "macOS \(testCase.major).\(testCase.minor).\(testCase.patch)"
            )
        }
    }

    func testColdStartRecoveryEnablesOnlyTheDiscoveredReceiverWithoutClaimingSelectionOrVolume() {
        let snapshot = merge()
        XCTAssertEqual(snapshot.routes.count, 1)
        XCTAssertEqual(snapshot.routes.first?.identifier, receiver)
        XCTAssertEqual(snapshot.routes.first?.name, "Discovered Bedroom")
        XCTAssertEqual(snapshot.routes.first?.uid, uid)
        XCTAssertEqual(snapshot.routes.first?.selectionCapability, .existingSystemStream)
        XCTAssertEqual(snapshot.routes.first?.isSelected, false)
        XCTAssertNil(snapshot.routes.first?.unavailableReason)
        XCTAssertNil(snapshot.selectedVolumeAssociation)
        XCTAssertNil(snapshot.warning)
    }

    func testIdentityAssociationAloneRemainsUnavailable() {
        var raw = retained()
        raw.removeValue(forKey: "existingStreamRecovery")
        let snapshot = merge(retained: raw)
        XCTAssertEqual(snapshot.routes.first?.uid, uid)
        XCTAssertEqual(snapshot.routes.first?.selectionCapability, .unavailable)
        XCTAssertEqual(snapshot.routes.first?.isSelected, false)
        XCTAssertNil(snapshot.selectedVolumeAssociation)
    }

    func testRecoveryCannotCreateAnUndiscoveredReceiver() {
        XCTAssertTrue(merge(endpoints: []).routes.isEmpty)
        let other = endpoint("another-receiver")
        let snapshot = merge(endpoints: [other])
        XCTAssertEqual(snapshot.routes.map(\.identifier), ["another-receiver"])
        XCTAssertEqual(snapshot.routes.first?.selectionCapability, .unavailable)
        XCTAssertNil(snapshot.routes.first?.uid)
    }

    func testRecoveryRequiresStrictBooleanAuthorizationAndReadback() {
        for key in ["canSelect", "readbackStable"] {
            for value: Any? in [nil, NSNull(), false, "true", NSNumber(value: 1), NSNumber(value: 0), [true]] {
                var evidence = recovery()
                evidence[key] = value
                var raw = retained()
                raw["existingStreamRecovery"] = evidence
                XCTAssertNil(PrivateRouteSnapshotAdapter.retainedSystemRoute(raw).existingStreamRecovery, key)
                assertUnavailable(merge(retained: raw), key)
            }
        }
    }

    func testRecoveryRequiresEveryNonemptyTypedIdentityAndAnExactAggregateUID() {
        for key in ["identifier", "name", "uid", "aggregateIdentifier", "contextIdentifier"] {
            for value: Any? in [nil, NSNull(), "", " \n ", 42, ["identity"]] {
                var evidence = recovery()
                evidence[key] = value
                var raw = retained()
                raw["existingStreamRecovery"] = evidence
                XCTAssertNil(PrivateRouteSnapshotAdapter.retainedSystemRoute(raw).existingStreamRecovery, key)
                assertUnavailable(merge(retained: raw), key)
            }
        }
        for stream in ["different-Audio", "\(aggregate)-100", "\(aggregate)-100-Audio-extra"] {
            var raw = retained()
            var evidence = recovery()
            evidence["uid"] = stream
            raw["existingStreamRecovery"] = evidence
            assertUnavailable(merge(retained: raw), stream)
        }
    }

    func testMissingMalformedOrExistingRetainedStateCannotBeOverridden() {
        for value: Any? in [nil, "uncaptured", [:],
            ["identifier": receiver, "canSelect": false, "state": "invalid", "reason": "Invalid capture"],
            ["identifier": receiver, "canSelect": false, "state": "pending"],
            ["identifier": receiver, "canSelect": false, "state": "cleanupRequired"]] {
            var raw = retained()
            raw["retained"] = value
            XCTAssertNil(PrivateRouteSnapshotAdapter.retainedSystemRoute(raw).existingStreamRecovery)
            assertUnavailable(merge(retained: raw))
        }
        var raw = retained()
        raw["retained"] = ["identifier": receiver, "canSelect": true, "state": "retained"]
        let snapshot = merge(retained: raw)
        XCTAssertEqual(snapshot.routes.first?.selectionCapability, .retainedAirPlay)
    }

    func testFailedOrMalformedSessionReadCannotReuseRecovery() {
        for value: Any? in [nil, NSNull(), false, "true", NSNumber(value: 1)] {
            var raw = retained()
            raw["sessionReadSucceeded"] = value
            let evidence = PrivateRouteSnapshotAdapter.retainedSystemRoute(raw)
            XCTAssertEqual(evidence.outcome, .failed)
            XCTAssertNil(evidence.existingStreamRecovery)
            assertUnavailable(merge(retained: raw))
        }
    }

    func testIndependentAssociationConflictCannotBeResolvedByRecoveryPrecedence() {
        for variant: [String: Any] in [
            ["identifier": "another-receiver"], ["uid": "\(aggregate)-101-Audio"],
            ["contextIdentifier": "another-context"],
            ["aggregateIdentifier": "12345678-abcd-4abc-8def-123456789abd",
             "uid": "12345678-abcd-4abc-8def-123456789abd-100-Audio"],
        ] {
            var raw = retained()
            raw["existingStreamAssociation"] = association().merging(variant) { _, new in new }
            assertUnavailable(merge(retained: raw))
        }
    }

    func testAVUnknownRequiresTheEstablishedIdentityAndEligibilityChecks() {
        let snapshot = merge(av: [av()])
        XCTAssertEqual(snapshot.routes.first?.selectionCapability, .existingSystemStream)
        XCTAssertEqual(snapshot.routes.first?.transportKind, .airplay)
        XCTAssertEqual(snapshot.routes.first?.name, "AV Bedroom")
        var missing = av()
        missing.removeValue(forKey: "selectionEvidence")
        assertUnavailable(merge(av: [missing]))
        var endpoint = endpoint()
        endpoint.removeValue(forKey: "avIdentity")
        assertUnavailable(merge(av: [av()], endpoints: [endpoint]))
        var restricted = av()
        restricted["selectionEvidence"] = ["contextWritable": false, "identityUnique": true,
            "deviceEligibility": ["supportsAudio": true, "isCached": true,
                                  "isDeviceDisabled": false, "requiresAuthorization": false]]
        assertUnavailable(merge(av: [restricted]))
    }

    func testRecoveryDoesNotReplaceAVCapabilityOrContradictItsExplicitUID() {
        var writable = av()
        writable["canSelect"] = true
        XCTAssertEqual(merge(av: [writable]).routes.first?.selectionCapability, .avSystemRoute)
        var conflict = av()
        conflict["uid"] = "different-stream"
        assertUnavailable(merge(av: [conflict]))
        var matching = av()
        matching["uid"] = uid
        XCTAssertEqual(merge(av: [matching]).routes.first?.selectionCapability, .existingSystemStream)
    }

    func testDuplicateRawDiscoveryIdentityAndConflictingUIDPreventRecovery() {
        assertUnavailable(merge(av: [av(), av()]))
        XCTAssertTrue(merge(endpoints: [endpoint(), endpoint()]).routes.isEmpty)
        var filteredDuplicate = endpoint()
        filteredDuplicate["wrapperIsCached"] = true
        assertUnavailable(merge(endpoints: [endpoint(), filteredDuplicate]))
        let other: [String: Any] = ["identifier": "other", "name": "Other", "uid": uid,
                                    "transport": "unknown", "canSelect": false]
        assertUnavailable(merge(av: [other]))
    }

    func testUnknownSelectedOrConflictingSelectionEvidenceNeverEnablesRecovery() {
        for selection: [String: Any] in [[:], ["selection": NSNull()],
            ["selection": NSNull(), "isUnselectedConfirmed": NSNumber(value: 1)]] {
            assertUnavailable(merge(selection: selection))
        }
        var selectedClaim = av()
        selectedClaim["isSelected"] = true
        assertUnavailable(merge(av: [selectedClaim]))
        let selected: [String: Any] = ["selection": ["identifier": receiver, "name": "System Bedroom", "uid": uid,
            "aggregateIdentifier": aggregate, "contextIdentifier": "context", "aggregateContextIdentifier": "context",
            "associatedUID": uid, "halUID": uid, "audioStreamUIDs": [uid],
            "memberIdentifiers": [receiver], "readbackStable": true]]
        let snapshot = merge(selection: selected)
        XCTAssertEqual(snapshot.routes.first?.isSelected, true)
        XCTAssertEqual(snapshot.routes.first?.selectionCapability, .unavailable)
        XCTAssertEqual(snapshot.selectedVolumeAssociation?.uid, uid, "Volume comes only from separate strict selection evidence.")
    }

    func testSupportingReadFailureOrPartialDiscoveryPreservesWarningWithoutRecovery() {
        let av = PrivateRouteSnapshotAdapter.avDiscovery([:])
        let endpoints = PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [endpoint()], "incompleteDeviceCount": 0])
        let selection = PrivateRouteSnapshotAdapter.systemSelection(unselected())
        let retained = PrivateRouteSnapshotAdapter.retainedSystemRoute(retained())
        let failure = NSError(domain: "fixture", code: 1)
        let samples = [
            PrivateRouteCatalog.merge(av: .failed(failure), endpoints: endpoints, selection: selection, retained: retained),
            PrivateRouteCatalog.merge(av: av, endpoints: .failed(failure), selection: selection, retained: retained),
            PrivateRouteCatalog.merge(av: av, endpoints: endpoints, selection: .failed(failure), retained: retained),
            PrivateRouteCatalog.merge(av: av, endpoints: endpoints, selection: selection, retained: .failed(failure)),
            PrivateRouteCatalog.merge(av: av, endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery([
                "endpoints": [endpoint()], "incompleteDeviceCount": 1]), selection: selection, retained: retained),
        ]
        for snapshot in samples {
            XCTAssertFalse(snapshot.routes.contains { $0.selectionCapability == .existingSystemStream })
            XCTAssertNotNil(snapshot.warning)
        }
    }

    func testBluetoothRemainsHALSelectedWhileRecoverableReceiverFoldsItsOldStream() {
        let bluetooth = AudioDevice(id: "hal:bluetooth-full-uid", name: "Bluetooth", transport: .bluetooth,
                                    backend: .coreAudio(uid: "bluetooth-full-uid"))
        let stream = AudioDevice(id: "hal:\(uid)", name: "AirPlay", transport: .airplay, backend: .coreAudio(uid: uid))
        let snapshot = merge()
        let catalog = AudioCatalog.merge(hal: CoreAudioSnapshot(devices: [bluetooth, stream],
            currentDeviceID: bluetooth.id, systemSoundDeviceID: bluetooth.id, warnings: []), routes: snapshot)
        XCTAssertEqual(catalog.currentDeviceID, bluetooth.id)
        XCTAssertEqual(catalog.devices.map(\.id), [bluetooth.id, "route:\(receiver)"])
        XCTAssertEqual(catalog.devices.last?.isAvailable, true)
        XCTAssertEqual(catalog.devices.last?.backend, .privateRoute(identifier: receiver))
        XCTAssertNil(snapshot.selectedVolumeAssociation)
    }

    private func assertUnavailable(_ snapshot: PrivateRouteSnapshot, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.routes.first { $0.identifier == receiver }?.selectionCapability,
                       .unavailable, message, file: file, line: line)
    }

    private func recovery() -> [String: Any] {
        ["identifier": receiver, "name": "Recovery Bedroom", "uid": uid,
         "aggregateIdentifier": aggregate, "contextIdentifier": "context", "readbackStable": true, "canSelect": true]
    }

    private func association() -> [String: Any] {
        ["identifier": receiver, "uid": uid, "aggregateIdentifier": aggregate,
         "contextIdentifier": "context", "readbackStable": true]
    }

    private func retained() -> [String: Any] {
        ["sessionReadSucceeded": true, "retained": NSNull(),
         "existingStreamAssociation": association(), "existingStreamRecovery": recovery()]
    }

    private func eligible() -> [String: Any] {
        ["supportsAudio": true, "isCached": false, "isDeviceDisabled": false, "requiresAuthorization": false]
    }

    private func endpoint(_ identifier: String? = nil) -> [String: Any] {
        let identifier = identifier ?? receiver
        return ["identifier": identifier, "name": "Discovered Bedroom", "deviceFeatures": 1,
            "isRemoteControlOnly": false, "wrapperIsCached": false, "isCached": false,
            "isDeviceDisabled": false, "requiresAuthorization": false, "deviceEligibility": eligible(),
            "avIdentity": ["endpointIdentifier": identifier, "avDeviceIdentifier": identifier, "readbackStable": true]]
    }

    private func av() -> [String: Any] {
        ["identifier": receiver, "name": "AV Bedroom", "transport": "unknown", "canSelect": false, "isSelected": false,
         "selectionEvidence": ["contextWritable": false, "identityUnique": true, "deviceEligibility": eligible()]]
    }

    private func unselected() -> [String: Any] {
        ["selection": NSNull(), "isUnselectedConfirmed": true]
    }

    private func merge(av: [[String: Any]] = [], endpoints: [[String: Any]]? = nil,
                       selection: [String: Any]? = nil, retained: [String: Any]? = nil) -> PrivateRouteSnapshot {
        PrivateRouteCatalog.merge(av: PrivateRouteSnapshotAdapter.avDiscovery(["routes": av]),
            endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery([
                "endpoints": endpoints ?? [endpoint()], "incompleteDeviceCount": 0]),
            selection: PrivateRouteSnapshotAdapter.systemSelection(selection ?? unselected()),
            retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(retained ?? self.retained()))
    }
}
