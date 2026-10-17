import Foundation
import XCTest
@testable import ToneHop

/// Exercises the production decoder and merger without constructing a native
/// bridge, starting discovery, or requesting a real output change.
final class PrivateRouteCatalogTests: XCTestCase {
    private let receiver = "bedroom"
    private let aggregate = "12345678-abcd-4abc-8def-123456789abc"
    private var stream: String { "\(aggregate)-123456789012345-Audio" }

    func testUIDEvidenceDistinguishesExplicitEmptyFromMissingMalformedAndUnknownText() {
        XCTAssertEqual(RouteStringEvidence(nil), .missing)
        XCTAssertEqual(RouteStringEvidence(NSNull()), .null)
        XCTAssertEqual(RouteStringEvidence(42), .malformed)
        XCTAssertEqual(RouteStringEvidence(["uid"]), .malformed)
        XCTAssertEqual(RouteStringEvidence(""), .value(""))
        XCTAssertEqual(RouteStringEvidence("unknown"), .value("unknown"))
    }

    func testAVUnknownClassificationDoesNotGrantSelectionAndKeepsValidatedAVCapabilitySeparate() {
        let evidence = PrivateRouteSnapshotAdapter.avDiscovery(["routes": [
            ["identifier": "unknown", "name": "Unknown"],
            ["identifier": "av", "name": "AV", "transport": "unknown", "canSelect": true],
            ["identifier": "malformed", "name": "Malformed", "transport": 7, "canSelect": "true"],
            ["name": "No identifier"],
        ]])
        XCTAssertEqual(evidence.routes.map(\.identifier), ["unknown", "av", "malformed"])
        XCTAssertEqual(evidence.routes.map(\.transportKind), [.other("unknown"), .other("unknown"), .other("unknown")])
        XCTAssertEqual(evidence.routes.map(\.selectionCapability), [.unavailable, .avSystemRoute, .unavailable])
        XCTAssertEqual(evidence.outcome, .succeeded)
    }

    func testFiveSourcesKeepSystemSelectionAuthoritativeWithoutBorrowingAnotherReceiversCapability() {
        let av: [String: Any] = ["routes": [
            ["identifier": receiver, "name": "AV name", "transport": "unknown", "canSelect": false],
            ["identifier": "other", "name": "Other", "transport": "unknown", "canSelect": true, "isSelected": true],
        ], "diagnostics": "av"]
        let endpoints: [String: Any] = ["endpoints": [endpoint(receiver), endpoint("endpoint-only")], "diagnostics": "endpoints"]
        var held = retainedSnapshot(uid: NSNull())
        held["existingStreamAssociation"] = association(uid: stream)
        held["diagnostics"] = ["systemRouteMemberComparison": [
            "systemContextMemberIDs": [receiver], "rawAggregateMemberIDs": [receiver],
            "readbackStable": true, "selectedForComparison": true,
        ]]
        let result = merge(av: av, endpoints: endpoints, selection: selectedSnapshot(), retained: held)

        XCTAssertEqual(result.routes.map(\.identifier), ["other", "endpoint-only", receiver])
        XCTAssertEqual(result.routes.map(\.isSelected), [false, false, true])
        XCTAssertEqual(result.routes.map(\.selectionCapability), [.avSystemRoute, .unavailable, .retainedAirPlay])
        XCTAssertEqual(result.routes.last?.name, "System Bedroom")
        XCTAssertEqual(result.routes.last?.uid, "selected-stream", "Unselected stream evidence cannot replace selected identity.")
        XCTAssertEqual(result.systemRouteMemberComparison?.comparison, .matches)
    }

    func testAVUnknownShadowsEndpointAndRetainedDescriptorBeforeSeparatePolicyChange() {
        // Characterization of the previous production precedence. Merely
        // extracting the merger must not silently enable a new selection path.
        let result = merge(
            av: ["routes": [["identifier": receiver, "name": "AV Bedroom", "transport": "unknown", "canSelect": false]]],
            endpoints: ["endpoints": [endpoint(receiver)]],
            retained: retainedSnapshot(uid: NSNull()))
        XCTAssertEqual(result.routes.count, 1)
        XCTAssertEqual(result.routes.first?.name, "AV Bedroom")
        XCTAssertEqual(result.routes.first?.transportKind, .other("unknown"))
        XCTAssertEqual(result.routes.first?.selectionCapability, .unavailable)
        XCTAssertNil(result.routes.first?.uid)
    }

    func testExistingStreamProvidesIdentityButCannotGrantCapabilityOrSelection() {
        let result = merge(endpoints: ["endpoints": [endpoint(receiver)]],
                           retained: ["existingStreamAssociation": association(uid: stream)])
        XCTAssertEqual(result.routes.count, 1)
        XCTAssertEqual(result.routes.first?.uid, stream)
        XCTAssertEqual(result.routes.first?.selectionCapability, .unavailable)
        XCTAssertEqual(result.routes.first?.isSelected, false)
        XCTAssertEqual(result.routes.first?.unavailableReason, RetainedRouteCapability.preparationHint)
    }

    func testRetainedReadFailureCannotReusePreviouslyDecodedCapabilityOrAssociation() {
        let av = PrivateRouteSnapshotAdapter.avDiscovery([:])
        let endpoints = PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [endpoint(receiver)], "incompleteDeviceCount": 0])
        let selection = PrivateRouteSnapshotAdapter.systemSelection([:])
        let valid = PrivateRouteSnapshotAdapter.retainedSystemRoute(retainedSnapshot(uid: stream))
        let before = PrivateRouteCatalog.merge(av: av, endpoints: endpoints, selection: selection, retained: valid)
        XCTAssertEqual(before.routes.first?.selectionCapability, .retainedAirPlay)
        XCTAssertEqual(before.routes.first?.uid, stream)

        let failed = RetainedSystemRouteEvidence.failed(failure())
        let after = PrivateRouteCatalog.merge(av: av, endpoints: endpoints, selection: selection, retained: failed)
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertNil(failed.capability)
        XCTAssertNil(failed.existingStreamAssociation)
        XCTAssertEqual(after.routes.first?.selectionCapability, .unavailable)
        XCTAssertNil(after.routes.first?.uid)
        XCTAssertFalse(after.routes.first?.isSelected ?? true)
        XCTAssertTrue(after.diagnostics.contains("RetainedSystemAudio error:"))
    }

    func testVerifiedAssociationWithRejectedCapabilityFoldsSurvivingAirPlayWhileBluetoothStaysSelected() {
        var raw = retainedSnapshot(uid: stream)
        var held = raw["retained"] as! [String: Any]
        held["canSelect"] = false
        held["state"] = "invalid"
        held["reason"] = "The original captured stream has changed"
        raw["retained"] = held
        let retained = PrivateRouteSnapshotAdapter.retainedSystemRoute(raw)
        let privateSnapshot = merge(endpoints: ["endpoints": [endpoint(receiver)]], retained: raw)
        let bluetooth = AudioDevice(id: "hal:bluetooth-full-uid", name: "Bluetooth headphones",
            transport: .bluetooth, backend: .coreAudio(uid: "bluetooth-full-uid"))
        let airplay = AudioDevice(id: "hal:\(stream)", name: "AirPlay", transport: .airplay,
                                  backend: .coreAudio(uid: stream))
        let catalog = AudioCatalog.merge(
            hal: CoreAudioSnapshot(devices: [bluetooth, airplay], currentDeviceID: bluetooth.id,
                                   systemSoundDeviceID: bluetooth.id, warnings: []), routes: privateSnapshot)

        XCTAssertEqual(catalog.devices.map(\.id), [bluetooth.id, "route:\(receiver)"])
        XCTAssertEqual(catalog.currentDeviceID, bluetooth.id)
        XCTAssertEqual(catalog.devices.last?.isAvailable, false)
        XCTAssertEqual(catalog.devices.last?.backend, .privateRoute(identifier: receiver))
        XCTAssertEqual(privateSnapshot.routes.first?.uid, stream)
        XCTAssertEqual(privateSnapshot.routes.first?.selectionCapability, .unavailable)
        XCTAssertEqual(privateSnapshot.routes.first?.isSelected, false)
        XCTAssertNil(privateSnapshot.selectedVolumeAssociation, "Identity alone cannot authorize receiver volume writes.")
        XCTAssertNil(retained.verifiedUnselectedDescriptor, "An invalid retained stream cannot create a selectable undiscovered receiver.")
        XCTAssertNil(catalog.warning)
    }

    func testOnlyExplicitNullUIDsPermitTheVerifiedEmptyAggregateDescriptor() {
        XCTAssertEqual(merge(retained: retainedSnapshot(uid: NSNull())).routes.first?.selectionCapability, .retainedAirPlay)
        for badUID: Any? in [nil, "", "unknown", 42] {
            var raw = retainedSnapshot(uid: NSNull())
            var held = raw["retained"] as! [String: Any]
            if let badUID { held["associatedUID"] = badUID }
            else { held.removeValue(forKey: "associatedUID") }
            raw["retained"] = held
            XCTAssertTrue(merge(retained: raw).routes.isEmpty, "Unknown or malformed association is not a verified empty aggregate.")
        }
        var raw = retainedSnapshot(uid: NSNull())
        var held = raw["retained"] as! [String: Any]
        var descriptor = held["catalogRoute"] as! [String: Any]
        descriptor.removeValue(forKey: "uid")
        held["catalogRoute"] = descriptor
        raw["retained"] = held
        XCTAssertTrue(merge(retained: raw).routes.isEmpty)
    }

    func testAllFailedReadsPublishUnavailableHealthInsteadOfAnEmptyHealthyCatalog() {
        let error = failure()
        let result = PrivateRouteCatalog.merge(av: .failed(error), endpoints: .failed(error),
                                              selection: .failed(error), retained: .failed(error))
        XCTAssertTrue(result.routes.isEmpty)
        XCTAssertEqual(result.warning, expectedLocalized("Network audio status could not be read. The AirPlay device list and current receiver cannot be confirmed.", "网络音频状态读取失败，AirPlay 设备列表与当前接收器暂无法确认。"))
        XCTAssertEqual(result.sourceHealth, PrivateRouteSourceHealth(avDiscovery: .failed,
            endpointDiscovery: .failed, systemSelection: .failed, retainedRoute: .failed))
        XCTAssertNil(result.systemRouteMemberComparison)
        for label in ["AVRouting error:", "FigEndpointManager error:", "SystemAudio error:", "RetainedSystemAudio error:", "AV issue: fixture failure"] {
            XCTAssertTrue(result.diagnostics.contains(label), label)
        }
    }

    func testEachPartialSourceFailureRemainsVisibleWithHealthyDiscoveryRows() {
        let av = PrivateRouteSnapshotAdapter.avDiscovery(["routes": [["identifier": "av", "name": "AV"]]])
        let endpoints = PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [endpoint(receiver)], "incompleteDeviceCount": 0])
        let selection = PrivateRouteSnapshotAdapter.systemSelection(["selection": NSNull(), "isUnselectedConfirmed": true])
        let retained = PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true])
        let error = failure()
        let samples = [
            PrivateRouteCatalog.merge(av: .failed(error), endpoints: endpoints, selection: selection, retained: retained),
            PrivateRouteCatalog.merge(av: av, endpoints: .failed(error), selection: selection, retained: retained),
            PrivateRouteCatalog.merge(av: av, endpoints: endpoints, selection: .failed(error), retained: retained),
            PrivateRouteCatalog.merge(av: av, endpoints: endpoints, selection: selection, retained: .failed(error)),
        ]
        for (sample, name) in zip(samples, [expectedLocalized("network device discovery", "网络设备发现"), expectedLocalized("receiver discovery", "接收器发现"), expectedLocalized("current receiver confirmation", "当前接收器确认"), expectedLocalized("receiver switching capability", "接收器切换能力")]) {
            XCTAssertFalse(sample.routes.isEmpty, "Working discovery sources remain usable.")
            XCTAssertTrue(sample.warning?.contains(expectedLocalized("Some network audio status could not be read (\(name))", "部分网络音频状态读取失败（\(name)）")) == true)
            XCTAssertNotNil(sample.sourceHealth)
        }
        XCTAssertEqual(samples[0].sourceHealth?.avDiscovery, .failed)
        XCTAssertEqual(samples[1].sourceHealth?.endpointDiscovery, .failed)
        XCTAssertEqual(samples[2].sourceHealth?.systemSelection, .failed)
        XCTAssertEqual(samples[3].sourceHealth?.retainedRoute, .failed)
    }

    func testSourceFailureWarningCoexistsWithIdentityWarningAndClearsOnHealthyRead() {
        let failed = PrivateRouteCatalog.merge(av: .failed(failure()),
            endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [endpoint(receiver), endpoint(receiver)], "incompleteDeviceCount": 0]),
            selection: PrivateRouteSnapshotAdapter.systemSelection([:]),
            retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true]))
        XCTAssertTrue(failed.warning?.contains(expectedLocalized("network device discovery", "网络设备发现")) == true)
        XCTAssertTrue(failed.warning?.contains(expectedLocalized("Some AirPlay devices cannot be identified", "部分 AirPlay 设备身份不明确")) == true)

        let recovered = merge()
        XCTAssertNil(recovered.warning)
        XCTAssertEqual(recovered.sourceHealth, PrivateRouteSourceHealth(avDiscovery: .succeeded,
            endpointDiscovery: .succeeded, systemSelection: .succeeded, retainedRoute: .succeeded))
        XCTAssertTrue(recovered.routes.isEmpty, "An empty successful read is distinct from source failure.")
    }

    func testEndpointAmbiguityAndDelayedPreparationWarningKeepTheirPrecedence() {
        let early = merge(endpoints: ["endpoints": [endpoint(receiver)], "elapsed": 7.9])
        XCTAssertNil(early.warning)
        let ready = merge(av: ["elapsed": 8.0], endpoints: ["endpoints": [endpoint(receiver)]])
        XCTAssertEqual(ready.warning, RetainedRouteCapability.preparationHint)
        let ambiguous = merge(av: ["elapsed": 9.0], endpoints: [
            "endpoints": [endpoint(receiver), endpoint(receiver), endpoint("other")],
        ])
        XCTAssertEqual(ambiguous.routes.map(\.identifier), ["other"])
        XCTAssertEqual(ambiguous.warning, expectedLocalized("Some AirPlay devices cannot be identified and are temporarily unavailable.", "部分 AirPlay 设备身份不明确，暂不可选择。"))
    }

    func testMalformedSystemSelectionDoesNotFallBackToAVSelectedClaim() {
        var selected = selectedSnapshot()["selection"] as! [String: Any]
        selected["associatedUID"] = "conflicting-stream"
        let result = merge(av: ["routes": [["identifier": "av-selected", "name": "AV", "isSelected": true]]],
                           endpoints: ["endpoints": [endpoint(receiver)]], selection: ["selection": selected])
        XCTAssertTrue(result.routes.filter(\.isSelected).isEmpty)
        XCTAssertEqual(result.routes.first?.selectionCapability, .unavailable)
    }

    func testAVSelectedClaimNeverBecomesFormalSelectionWithoutStrictReadback() {
        for uid: Any? in [nil, "airplay-stream"] {
            var row: [String: Any] = ["identifier": receiver, "name": "AV Bedroom", "isSelected": true]
            if let uid { row["uid"] = uid }
            let av = PrivateRouteSnapshotAdapter.avDiscovery(["routes": [row]])
            XCTAssertFalse(av.routes[0].isSelected)
            XCTAssertEqual(av.selectionEvidence[receiver]?.isSelected, true,
                           "The AV claim remains a capability constraint, not selected-output evidence.")
            let unknown = PrivateRouteSnapshotAdapter.systemSelection([:])
            let unselected = PrivateRouteSnapshotAdapter.systemSelection(["selection": NSNull(), "isUnselectedConfirmed": true])
            for selection in [unknown, unselected, .failed(failure())] {
                let result = PrivateRouteCatalog.merge(av: av,
                    endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [], "incompleteDeviceCount": 0]), selection: selection,
                    retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true]))
                XCTAssertEqual(result.routes.count, 1)
                XCTAssertTrue(result.routes.allSatisfy { !$0.isSelected })
            }
        }
    }

    func testDiscoveryValueClaimsCannotBypassTheStrictSelectionSource() {
        let claimed = PrivateAudioRoute(identifier: receiver, name: "Claimed", uid: "stream",
                                        isSelected: true, canSelect: false, transport: "airplay")
        let av = AVRouteDiscoveryEvidence(routes: [claimed], elapsed: 0, issue: nil,
                                         diagnostics: "fixture", outcome: .succeeded)
        let result = PrivateRouteCatalog.merge(av: av,
            endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": [], "incompleteDeviceCount": 0]),
            selection: .failed(failure()), retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true]))
        XCTAssertEqual(result.routes.first?.isSelected, false)
    }

    func testRetryClassificationUsesTheDeclaredDomainAndKeepsOtherStatusesTerminal() {
        XCTAssertEqual(RetainedRouteFailure(NSError(domain: THRetainedAudioErrorDomain,
                                                    code: THRetainedAudioError.pending.rawValue)), .pending)
        XCTAssertEqual(RetainedRouteFailure(NSError(domain: THRetainedAudioErrorDomain,
                                                    code: THRetainedAudioError.cleanupBlocked.rawValue)), .blocked)
        XCTAssertEqual(RetainedRouteFailure(NSError(domain: "another-domain",
                                                    code: THRetainedAudioError.pending.rawValue)), .failed)
        XCTAssertEqual(RetainedRouteFailure(NSError(domain: THRetainedAudioErrorDomain, code: -16727)), .failed)
    }

    private func merge(av: [String: Any] = [:], endpoints: [String: Any] = [:],
                       selection: [String: Any] = ["selection": NSNull(), "isUnselectedConfirmed": true],
                       retained: [String: Any] = [:]) -> PrivateRouteSnapshot {
        let endpointSnapshot: [String: Any] = ["endpoints": [], "incompleteDeviceCount": 0].merging(endpoints) { _, value in value }
        let retainedSnapshot: [String: Any] = ["sessionReadSucceeded": true].merging(retained) { _, value in value }
        return PrivateRouteCatalog.merge(av: PrivateRouteSnapshotAdapter.avDiscovery(av),
                                  endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(endpointSnapshot),
                                  selection: PrivateRouteSnapshotAdapter.systemSelection(selection),
                                  retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(retainedSnapshot))
    }

    private func endpoint(_ identifier: String) -> [String: Any] {
        ["identifier": identifier, "name": "Endpoint \(identifier)", "deviceFeatures": 1,
         "isRemoteControlOnly": false, "wrapperIsCached": false]
    }

    private func selectedSnapshot() -> [String: Any] {
        ["selection": ["identifier": receiver, "name": "System Bedroom", "uid": "selected-stream",
                       "aggregateIdentifier": aggregate, "contextIdentifier": "context",
                       "aggregateContextIdentifier": "context", "associatedUID": "selected-stream",
                       "halUID": "selected-stream", "audioStreamUIDs": ["selected-stream"],
                       "memberIdentifiers": [receiver], "readbackStable": true]]
    }

    private func retainedSnapshot(uid: Any) -> [String: Any] {
        ["sessionReadSucceeded": true, "retained": ["identifier": receiver, "canSelect": true, "associatedUID": uid,
                      "associationReadbackStable": uid is String,
                      "state": "retained", "isSelected": false,
                      "catalogRoute": ["identifier": receiver, "name": "Held Bedroom", "transport": "airplay",
                                       "uid": uid, "readbackStable": true]]]
    }

    private func association(uid: String) -> [String: Any] {
        ["identifier": receiver, "uid": uid, "aggregateIdentifier": aggregate,
         "contextIdentifier": "context", "readbackStable": true]
    }

    private func failure() -> NSError {
        NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture failure"])
    }
}
