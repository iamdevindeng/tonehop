import XCTest
@testable import ToneHop

final class ExistingSystemStreamAssociationTests: XCTestCase {
    private let aggregate = "12345678-abcd-4abc-8def-123456789abc"
    private var uid: String { "\(aggregate)-123456789012345-Audio" }

    func testLocalStartupWithExistingStreamHasOneDisabledReceiverAndKeepsLocalSelection() {
        let local = AudioDevice(id: "hal:local", name: "Mac mini Speakers", transport: .speaker,
                                backend: .coreAudio(uid: "local"))
        let stream = AudioDevice(id: "hal:\(uid)", name: "AirPlay", transport: .airplay, backend: .coreAudio(uid: uid))
        let discovery = RetainedRouteCapability.applying(nil, to: [route()])
        XCTAssertFalse(discovery[0].canSelect, "The new process has no retained aggregate.")
        let routes = ExistingSystemStreamAssociation.applying(association(), to: discovery)
        let catalog = AudioCatalog.merge(
            hal: CoreAudioSnapshot(devices: [local, stream], currentDeviceID: local.id,
                                   systemSoundDeviceID: local.id, warnings: [], confirmedDeviceObjects: ["local": 1, uid: 2]),
            routes: PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "fresh live-stream fixture"))

        XCTAssertEqual(catalog.devices.map(\.id), [local.id, "route:bedroom"])
        XCTAssertFalse(catalog.devices[1].isAvailable)
        XCTAssertEqual(catalog.devices[1].backend, .privateRoute(identifier: "bedroom"))
        XCTAssertEqual(catalog.devices[1].unavailableReason, RetainedRouteCapability.preparationHint)
        XCTAssertEqual(catalog.currentDeviceID, local.id)
        XCTAssertFalse(routes[0].isSelected)
        XCTAssertNil(catalog.warning)
    }

    func testFreshAssociationCannotCreateMissingReceiverOrGuessSameNameOrResolveDuplicates() {
        let evidence = association()
        XCTAssertTrue(ExistingSystemStreamAssociation.applying(evidence, to: []).isEmpty)
        let different = route(id: "different-id")
        XCTAssertEqual(ExistingSystemStreamAssociation.applying(evidence, to: [different]), [different])
        let duplicate = [route(), route()]
        XCTAssertEqual(ExistingSystemStreamAssociation.applying(evidence, to: duplicate), duplicate)
    }

    func testAssociationDoesNotOverrideExplicitConflictingUIDOrSelectionEvidence() {
        for original in [route(uid: "another-stream"), route(selected: true), route(transport: "unknown")] {
            XCTAssertEqual(ExistingSystemStreamAssociation.applying(association(), to: [original]), [original])
        }
    }

    func testNoStableLiveEvidenceDoesNotReusePreviousAssociation() {
        let discovery = [route()]
        XCTAssertEqual(ExistingSystemStreamAssociation.applying(association(), to: discovery)[0].uid, uid)
        XCTAssertEqual(ExistingSystemStreamAssociation.applying(nil, to: discovery), discovery)
        var evidence = fixture()
        evidence["readbackStable"] = false
        XCTAssertNil(ExistingSystemStreamAssociation(snapshot: ["existingStreamAssociation": evidence]))
        for key in ["identifier", "uid", "aggregateIdentifier", "contextIdentifier", "readbackStable"] {
            var missing = fixture()
            missing.removeValue(forKey: key)
            XCTAssertNil(ExistingSystemStreamAssociation(snapshot: ["existingStreamAssociation": missing]), key)
        }
    }

    func testAssociationCannotRestoreRejectedRetainedCapabilityOrClearItsReason() {
        let reason = "The live leaf is no longer eligible"
        let retained = RetainedRouteCapability(snapshot: ["retained": [
            "identifier": "bedroom", "canSelect": false, "reason": reason,
        ]])
        let routes = ExistingSystemStreamAssociation.applying(association(), to:
            RetainedRouteCapability.applying(retained, to: [route()]))

        XCTAssertEqual(routes[0].uid, uid, "Valid identity may still deduplicate an unavailable receiver.")
        XCTAssertFalse(routes[0].canSelect)
        XCTAssertFalse(routes[0].isSelected)
        XCTAssertEqual(routes[0].unavailableReason, reason)
    }

    func testAssociationPreservesValidRetainedSwitchingCapabilityAfterLeavingReceiver() {
        let retained = RetainedRouteCapability(snapshot: ["retained": [
            "identifier": "bedroom", "canSelect": true,
        ]])
        let routes = ExistingSystemStreamAssociation.applying(association(), to:
            RetainedRouteCapability.applying(retained, to: [route()]))

        XCTAssertEqual(routes[0].uid, uid)
        XCTAssertTrue(routes[0].canSelect)
        XCTAssertFalse(routes[0].isSelected)
    }

    func testSelectedStartupRemainsAvailableWithCompleteRetainedReferences() {
        let retained = RetainedRouteCapability(snapshot: ["retained": [
            "identifier": "bedroom", "canSelect": true,
        ]])
        let routes = ExistingSystemStreamAssociation.applying(association(), to:
            RetainedRouteCapability.applying(retained, to: [route(uid: uid, selected: true)]))
        let stream = AudioDevice(id: "hal:\(uid)", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: uid))
        let catalog = AudioCatalog.merge(
            hal: CoreAudioSnapshot(devices: [stream], currentDeviceID: stream.id,
                                   systemSoundDeviceID: stream.id, warnings: [], confirmedDeviceObjects: [uid: 2]),
            routes: PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "selected startup fixture"))

        XCTAssertEqual(catalog.devices.map(\.id), ["route:bedroom"])
        XCTAssertEqual(catalog.currentDeviceID, "route:bedroom")
        XCTAssertTrue(catalog.devices[0].isAvailable)
        XCTAssertNil(catalog.devices[0].unavailableReason)
        XCTAssertNil(catalog.warning)
    }

    func testAssociationCannotSupplyMissingSystemSelectionReadback() {
        let stream = AudioDevice(id: "hal:\(uid)", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: uid))
        let routes = ExistingSystemStreamAssociation.applying(association(), to: [route()])
        let catalog = AudioCatalog.merge(
            hal: CoreAudioSnapshot(devices: [stream], currentDeviceID: stream.id,
                                   systemSoundDeviceID: stream.id, warnings: []),
            routes: PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "identity only fixture"))

        XCTAssertEqual(catalog.devices.map(\.id), ["route:bedroom"])
        XCTAssertFalse(routes[0].isSelected)
        XCTAssertNil(catalog.currentDeviceID)
        XCTAssertNotNil(catalog.warning)
    }

    func testOnlyExplicitAssociationFieldProvidesIdentity() {
        XCTAssertNil(ExistingSystemStreamAssociation(snapshot: ["existingStream": fixture()]))
        XCTAssertNil(ExistingSystemStreamAssociation(snapshot: ["retained": fixture()]))
        var conflicting = fixture()
        conflicting["aggregateIdentifier"] = "another-aggregate"
        XCTAssertNil(ExistingSystemStreamAssociation(snapshot: ["existingStreamAssociation": conflicting]))
    }

    func testExactStreamGrammarAcceptsOnlyCompleteCanonicalUInt64Generation() {
        for generation in ["0", "1", "123456789012345", "18446744073709551615"] {
            XCTAssertTrue(THExistingStreamUIDMatchesAggregate("\(aggregate)-\(generation)-Audio", aggregate))
        }
        for generation in ["", "00", "01", "-1", "+1", " 1", "1 ", "1x", "1.0", "18446744073709551616", "١"] {
            XCTAssertFalse(THExistingStreamUIDMatchesAggregate("\(aggregate)-\(generation)-Audio", aggregate), generation)
        }
        for candidate in [aggregate, "\(aggregate)-1", "\(uid)-extra", "\(aggregate)-1-audio", "prefix-\(uid)"] {
            XCTAssertFalse(THExistingStreamUIDMatchesAggregate(candidate, aggregate), candidate)
        }
        XCTAssertFalse(THExistingStreamUIDMatchesAggregate(uid, aggregate.uppercased()))
        XCTAssertFalse(THExistingStreamUIDMatchesAggregate("-1-Audio", ""))
    }

    private func fixture() -> [String: Any] {
        ["identifier": "bedroom", "uid": uid, "aggregateIdentifier": aggregate,
         "contextIdentifier": "system-audio-context", "readbackStable": true]
    }

    private func association() -> ExistingSystemStreamAssociation? {
        ExistingSystemStreamAssociation(snapshot: ["existingStreamAssociation": fixture()])
    }

    private func route(id: String = "bedroom", uid: String? = nil, selected: Bool = false,
                       transport: String = "airplay") -> PrivateAudioRoute {
        PrivateAudioRoute(identifier: id, name: "Bedroom", uid: uid, isSelected: selected,
                          canSelect: false, transport: transport)
    }
}
