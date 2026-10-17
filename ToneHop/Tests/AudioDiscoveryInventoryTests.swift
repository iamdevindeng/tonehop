import Foundation
import XCTest
@testable import ToneHop

final class AudioDiscoveryInventoryTests: XCTestCase {
    func testNoEvidenceDoesNotReportSavedTargetsMissing() {
        XCTAssertEqual(AudioDiscoveryInventory.unconfirmed.presence(of: .hal(uid: "usb")), .unconfirmed)
        XCTAssertEqual(AudioDiscoveryInventory.unconfirmed.presence(of: .receiver(identifier: "bedroom")), .unconfirmed)
    }

    func testCompleteHALAbsenceIsIndependentOfFailedPrivateDiscovery() {
        let inventory = AudioDiscoveryInventory(hal: .init(observedIdentifiers: ["speakers"], isComplete: true))
        XCTAssertEqual(inventory.presence(of: .hal(uid: "speakers")), .found)
        XCTAssertEqual(inventory.presence(of: .hal(uid: "usb")), .missing)
        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "bedroom")), .unconfirmed)
    }

    func testPartialHALInventoryAndRawIdentityConflictCannotProveAbsence() {
        let partial = CoreAudioIdentityInventory.discovery([.init(objectID: 1, uid: "speakers")], complete: false)
        XCTAssertEqual(partial.presence(of: "speakers"), .found)
        XCTAssertEqual(partial.presence(of: "usb"), .unconfirmed)
        let duplicate = CoreAudioIdentityInventory.discovery([
            .init(objectID: 1, uid: "same"), .init(objectID: 2, uid: "same"),
        ], complete: true)
        XCTAssertEqual(duplicate.presence(of: "same"), .found, "Presence is independent of unique binding identity.")
        XCTAssertEqual(duplicate.presence(of: "other"), .unconfirmed)
    }

    func testAVRawInventorySurvivesFilteredDisplayButMissingEnvelopeDoesNotProveAbsence() {
        let raw = avRaw(ids: ["filtered-device"])
        let source = PrivateRouteSnapshotAdapter.avDiscovery(raw)
        XCTAssertTrue(source.routes.isEmpty)
        XCTAssertEqual(source.discovery.presence(of: "filtered-device"), .found)
        XCTAssertEqual(source.discovery.presence(of: "other"), .missing)
        XCTAssertEqual(PrivateRouteSnapshotAdapter.avDiscovery(["routes": []]).discovery.presence(of: "other"), .unconfirmed)
    }

    func testAVMalformedOrConflictedRawInventoryCannotProveAbsence() {
        var raw = avRaw(ids: ["duplicate", "duplicate"])
        let duplicate = PrivateRouteSnapshotAdapter.avDiscovery(raw).discovery
        XCTAssertEqual(duplicate.presence(of: "duplicate"), .found)
        XCTAssertEqual(duplicate.presence(of: "saved"), .unconfirmed)
        raw["discoveryIdentity"] = ["identifiers": [], "conflictedIdentifiers": [], "isComplete": NSNumber(value: 1)]
        XCTAssertEqual(PrivateRouteSnapshotAdapter.avDiscovery(raw).discovery.presence(of: "saved"), .unconfirmed)
    }

    func testEndpointCompletenessNeedsUnfilteredCountAndValidIdentities() {
        for raw: [String: Any] in [
            ["endpoints": [], "incompleteDeviceCount": 0],
            ["endpoints": [], "endpointCount": 1, "incompleteDeviceCount": 0],
            ["endpoints": [["identifier": NSNull()]], "endpointCount": 1, "incompleteDeviceCount": 0],
            ["endpoints": [], "endpointCount": 0, "incompleteDeviceCount": 1],
        ] {
            XCTAssertEqual(PrivateRouteSnapshotAdapter.endpointDiscovery(raw).discovery.presence(of: "saved"), .unconfirmed)
        }
        XCTAssertEqual(PrivateRouteSnapshotAdapter.endpointDiscovery(endpointRaw()).discovery.presence(of: "saved"), .missing)
    }

    func testEndpointChangedOrFailedSecondRawIdentityCannotDeclareSavedReadbackIdentityMissing() {
        for readback: Any in ["B", NSNull()] {
            let row: [String: Any] = ["identifier": "A", "name": "Receiver", "deviceFeatures": 1,
                "isRemoteControlOnly": false, "wrapperIsCached": false,
                "discoveryIdentity": ["identifier": "A", "readbackIdentifier": readback, "readbackStable": false]]
            let source = PrivateRouteSnapshotAdapter.endpointDiscovery([
                "endpoints": [row], "endpointCount": 1, "incompleteDeviceCount": 0, "elapsed": 10])
            XCTAssertEqual(source.discovery.presence(of: "B"), .unconfirmed)
        }
    }

    func testStableRawEndpointIdentityDoesNotRequireAVWrapperIdentity() {
        let row: [String: Any] = ["identifier": "A", "isRemoteControlOnly": true,
            "wrapperIsCached": NSNull(), "avIdentity": ["readbackStable": false],
            "discoveryIdentity": ["identifier": "A", "readbackIdentifier": "A", "readbackStable": true]]
        let source = PrivateRouteSnapshotAdapter.endpointDiscovery([
            "endpoints": [row], "endpointCount": 1, "incompleteDeviceCount": 0, "elapsed": 10])
        XCTAssertEqual(source.discovery.presence(of: "A"), .found)
        XCTAssertEqual(source.discovery.presence(of: "B"), .missing)
    }

    func testPrivateStartupWaitsForBothCompleteSourcesAndSettlingInterval() {
        for elapsed in [0.0, 7.999] {
            let snapshot = privateSnapshot(av: avRaw(elapsed: elapsed), endpoints: endpointRaw(elapsed: 20))
            XCTAssertEqual(snapshot.discovery.presence(of: "saved"), .unconfirmed)
        }
        let settled = privateSnapshot(av: avRaw(), endpoints: endpointRaw())
        XCTAssertEqual(settled.discovery.presence(of: "saved"), .missing)
        let failed = PrivateRouteCatalog.merge(av: .failed(AudioServiceError.targetMissing),
            endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(endpointRaw()),
            selection: unselected(), retained: emptyRetained())
        XCTAssertEqual(failed.discovery.presence(of: "saved"), .unconfirmed)
    }

    func testRetainedDescriptorAndBindingCapabilityCannotCountAsDiscovery() {
        let retainedRoute = PrivateAudioRoute(identifier: "saved", name: "Saved receiver", uid: nil,
            isSelected: false, transportKind: .airplay, selectionCapability: .retainedAirPlay)
        let retained = RetainedSystemRouteEvidence(
            capability: .init(identifier: "saved", canSelect: true, reason: nil, associatedUID: nil, catalogRoute: retainedRoute),
            existingStreamAssociation: nil, memberComparison: nil, diagnostics: "retained fixture", outcome: .succeeded,
            verifiedUnselectedDescriptor: retainedRoute)
        let snapshot = PrivateRouteCatalog.merge(av: PrivateRouteSnapshotAdapter.avDiscovery(avRaw()),
            endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(endpointRaw()), selection: unselected(), retained: retained)
        XCTAssertEqual(snapshot.routes.map(\.identifier), ["saved"])
        XCTAssertEqual(snapshot.confirmedShortcutIdentifiers, ["saved"])
        XCTAssertEqual(snapshot.discovery.presence(of: "saved"), .missing)
    }

    func testActualSelectedReceiverProtectsRecordDespiteFailedDiscovery() {
        let selected = PrivateAudioRoute(identifier: "playing", name: "Playing", uid: "stream", isSelected: true,
            transportKind: .airplay, selectionCapability: .unavailable)
        let snapshot = PrivateRouteCatalog.merge(av: .failed(AudioServiceError.targetMissing),
            endpoints: .failed(AudioServiceError.targetMissing),
            selection: .init(route: selected, diagnostics: "strict selected fixture", outcome: .succeeded),
            retained: emptyRetained())
        XCTAssertEqual(snapshot.discovery.presence(of: "playing"), .found)
        XCTAssertEqual(snapshot.discovery.presence(of: "other"), .unconfirmed)
    }

    func testLiveHALAssociationProtectsReceiverAndUnknownAirPlayBlocksAbsence() {
        let stream = AudioDevice(id: "hal:stream", name: "AirPlay", transport: .airplay, backend: .coreAudio(uid: "stream"))
        let hal = CoreAudioSnapshot(devices: [stream], currentDeviceID: stream.id, systemSoundDeviceID: nil, warnings: [],
            confirmedDeviceObjects: ["stream": 1], discovery: .init(observedIdentifiers: ["stream"], isComplete: true),
            isOutputInventoryComplete: true)
        var snapshot = PrivateRouteSnapshot(routes: [], warning: nil, diagnostics: "complete empty discovery",
            discovery: .init(isComplete: true))
        XCTAssertEqual(AudioDiscoveryInventory.merge(hal: hal, routes: snapshot).presence(of: .receiver(identifier: "saved")), .unconfirmed)
        snapshot = .init(routes: [PrivateAudioRoute(identifier: "saved", name: "Saved", uid: "stream", isSelected: false,
            transportKind: .airplay, selectionCapability: .unavailable)], warning: nil, diagnostics: "live exact association",
            discovery: .init(isComplete: true))
        let inventory = AudioDiscoveryInventory.merge(hal: hal, routes: snapshot)
        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "saved")), .found)
        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "other")), .missing)
    }

    func testIncompleteHALOutputProjectionBlocksReceiverAbsenceDespiteCompleteRawIdentities() {
        let hal = CoreAudioSnapshot(devices: [], currentDeviceID: nil, systemSoundDeviceID: nil, warnings: [],
            confirmedDeviceObjects: ["stream": 1], discovery: .init(observedIdentifiers: ["stream"], isComplete: true),
            isOutputInventoryComplete: false)
        let routes = PrivateRouteSnapshot(routes: [], warning: nil, diagnostics: "complete empty discovery",
            discovery: .init(isComplete: true))

        let inventory = AudioDiscoveryInventory.merge(hal: hal, routes: routes)

        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "saved")), .unconfirmed,
            "An unreadable output could be an unassociated live AirPlay stream.")
        XCTAssertEqual(inventory.presence(of: .hal(uid: "stream")), .found)
        XCTAssertEqual(inventory.presence(of: .hal(uid: "absent-usb")), .missing,
            "A complete raw UID inventory independently establishes HAL absence.")
    }

    func testIncompleteRawHALInventoryBlocksReceiverAbsenceDespiteCompleteOutputProjection() {
        let hal = CoreAudioSnapshot(devices: [], currentDeviceID: nil, systemSoundDeviceID: nil, warnings: [],
            discovery: .init(isComplete: false), isOutputInventoryComplete: true)
        let routes = PrivateRouteSnapshot(routes: [], warning: nil, diagnostics: "complete empty discovery",
            discovery: .init(isComplete: true))

        let inventory = AudioDiscoveryInventory.merge(hal: hal, routes: routes)

        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "saved")), .unconfirmed)
        XCTAssertEqual(inventory.presence(of: .hal(uid: "absent-usb")), .unconfirmed)
    }

    func testRawAssociatedUIDWithoutProjectedOutputKeepsReceiverUnconfirmedAndUnavailable() {
        let hal = CoreAudioSnapshot(devices: [], currentDeviceID: nil, systemSoundDeviceID: nil, warnings: [],
            confirmedDeviceObjects: ["stream": 1], discovery: .init(observedIdentifiers: ["stream"], isComplete: true),
            isOutputInventoryComplete: true)
        let retained = PrivateAudioRoute(identifier: "saved", name: "Saved receiver", uid: "stream", isSelected: false,
            transportKind: .airplay, selectionCapability: .retainedAirPlay)
        let routes = PrivateRouteSnapshot(routes: [retained], warning: nil, diagnostics: "retained descriptor",
            confirmedShortcutIdentifiers: ["saved"], discovery: .init(isComplete: true))

        let inventory = AudioDiscoveryInventory.merge(hal: hal, routes: routes)
        let catalog = AudioCatalog.merge(hal: hal, routes: routes)

        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "saved")), .unconfirmed)
        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "other")), .unconfirmed)
        XCTAssertEqual(catalog.devices.map(\.id), ["route:saved"])
        XCTAssertFalse(catalog.devices[0].isAvailable,
            "A raw UID without a current output row cannot authorize the retained capability.")
        XCTAssertNil(catalog.devices[0].shortcutTarget)
        XCTAssertNil(catalog.currentDeviceID)
    }

    func testRawConflictWinsOverLiveAssociationAndCannotAuthorizeMissingRecords() {
        let stream = AudioDevice(id: "hal:stream", name: "AirPlay", transport: .airplay, backend: .coreAudio(uid: "stream"))
        let hal = CoreAudioSnapshot(devices: [stream], currentDeviceID: stream.id, systemSoundDeviceID: nil, warnings: [],
            confirmedDeviceObjects: ["stream": 1])
        let routes = ["first", "second"].map { PrivateAudioRoute(identifier: $0, name: $0, uid: "stream", isSelected: false,
            transportKind: .airplay, selectionCapability: .unavailable) }
        let snapshot = PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "conflicting association",
            discovery: .init(isComplete: true))
        let inventory = AudioDiscoveryInventory.merge(hal: hal, routes: snapshot)
        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "first")), .unconfirmed)
        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "other")), .unconfirmed)
    }

    private func avRaw(ids: [String] = [], elapsed: Double = 8) -> [String: Any] {
        ["routes": [], "elapsed": elapsed,
         "discoveryIdentity": ["identifiers": ids, "conflictedIdentifiers": [String](), "isComplete": true]]
    }

    private func endpointRaw(elapsed: Double = 8) -> [String: Any] {
        ["endpoints": [], "endpointCount": 0, "incompleteDeviceCount": 0, "elapsed": elapsed]
    }

    private func unselected() -> SystemSelectionEvidence {
        .init(route: nil, diagnostics: "unselected fixture", outcome: .succeeded, confirmsUnselectedAggregate: true)
    }

    private func emptyRetained() -> RetainedSystemRouteEvidence {
        .init(capability: nil, existingStreamAssociation: nil, memberComparison: nil, diagnostics: "none", outcome: .succeeded)
    }

    private func privateSnapshot(av: [String: Any], endpoints: [String: Any]) -> PrivateRouteSnapshot {
        PrivateRouteCatalog.merge(av: PrivateRouteSnapshotAdapter.avDiscovery(av),
            endpoints: PrivateRouteSnapshotAdapter.endpointDiscovery(endpoints), selection: unselected(), retained: emptyRetained())
    }
}
