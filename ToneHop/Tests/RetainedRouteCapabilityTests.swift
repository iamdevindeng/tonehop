import XCTest
@testable import ToneHop

final class RetainedRouteCapabilityTests: XCTestCase {
    func testCapabilityEnablesOnlyTheExactLiveReceiverWithoutChangingSelectionOrUID() {
        let live = route(id: "bedroom", selected: false, uid: nil)
        let other = route(id: "other", selected: false, uid: nil)
        let result = RetainedRouteCapability.applying(capability(id: "bedroom", ready: true), to: [live, other])

        XCTAssertEqual(result.map(\.identifier), ["bedroom", "other"])
        XCTAssertTrue(result[0].canSelect)
        XCTAssertFalse(result[1].canSelect)
        XCTAssertFalse(result[0].isSelected, "Holding a valid route must not manufacture a selected checkmark.")
        XCTAssertNil(result[0].uid, "A previous aggregate stream must not become the current HAL association.")
        XCTAssertEqual(result[0].name, live.name)
        XCTAssertEqual(result[0].transport, live.transport)
    }

    func testRetainedHandleCannotCreateARowOrMatchAReceiverByName() {
        let retained = capability(id: "old-id", ready: true, associatedUID: "captured-stream")
        XCTAssertTrue(RetainedRouteCapability.applying(retained, to: []).isEmpty)
        let liveWithSameName = route(id: "different-id", selected: false, uid: nil)
        let result = RetainedRouteCapability.applying(retained, to: [liveWithSameName])

        XCTAssertEqual(result.map(\.identifier), ["different-id"])
        XCTAssertFalse(result[0].canSelect)
        XCTAssertNil(result[0].uid)
    }

    func testImmediateLeaveBeforeDiscoveryIsReadyPreservesTheCapturedReceiverRow() {
        let local = AudioDevice(id: "hal:local", name: "Local", transport: .speaker, backend: .coreAudio(uid: "local"))
        let stream = AudioDevice(id: "hal:captured-stream", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: "captured-stream"))
        // Startup has no discovery endpoints. The system-selected route alone
        // supplies Bedroom, and capture validates its retained reference.
        let before = AudioCatalog.merge(
            hal: CoreAudioSnapshot(devices: [local, stream], currentDeviceID: stream.id,
                                   systemSoundDeviceID: local.id, warnings: []),
            routes: PrivateRouteSnapshot(routes: RetainedRouteCapability.applying(capability(id: "bedroom", ready: true), to: [
                route(id: "bedroom", selected: true, uid: "captured-stream"),
            ]), warning: nil, diagnostics: "selected, endpointCount=0")
        )
        // The immediate local switch removes the system-selected row before
        // discovery's first result. A newly verified empty aggregate keeps it.
        let retainedRoutes = RetainedRouteCapability.applying(RetainedRouteCapability(snapshot: catalogSnapshot()), to: [])
        let after = AudioCatalog.merge(
            hal: CoreAudioSnapshot(devices: [local], currentDeviceID: local.id,
                                   systemSoundDeviceID: local.id, warnings: []),
            routes: PrivateRouteSnapshot(routes: retainedRoutes, warning: nil, diagnostics: "local, endpointCount=0")
        )

        XCTAssertEqual(before.currentDeviceID, "route:bedroom")
        XCTAssertEqual(after.currentDeviceID, local.id)
        XCTAssertEqual(after.devices, before.devices)
        XCTAssertEqual(after.devices.map(\.id), [local.id, "route:bedroom"])
        XCTAssertEqual(retainedRoutes.count, 1)
        XCTAssertEqual(retainedRoutes.first?.canSelect, true)
        XCTAssertEqual(retainedRoutes.first?.isSelected, false)
        XCTAssertNil(retainedRoutes.first?.uid, "A cleared aggregate cannot reuse its old capture UID for deduplication.")
        XCTAssertNil(after.warning)
    }

    func testDiscoveryArrivalReplacesHeldDescriptorWithoutADuplicateOrStaleName() {
        let retained = RetainedRouteCapability(snapshot: catalogSnapshot())
        let beforeDiscovery = RetainedRouteCapability.applying(retained, to: [])
        let discovered = PrivateAudioRoute(identifier: "bedroom", name: "Bedroom renamed", uid: nil,
                                           isSelected: false, canSelect: false, transport: "airplay")
        let afterDiscovery = RetainedRouteCapability.applying(retained, to: [discovered])

        XCTAssertEqual(beforeDiscovery.map(\.identifier), ["bedroom"])
        XCTAssertEqual(afterDiscovery.map(\.identifier), ["bedroom"])
        XCTAssertEqual(afterDiscovery[0].name, discovered.name)
        XCTAssertTrue(afterDiscovery[0].canSelect)
        XCTAssertFalse(afterDiscovery[0].isSelected)
    }

    func testVerifiedHeldDescriptorFoldsItsSurvivingHALStreamBeforeDiscoveryIsReady() {
        let local = AudioDevice(id: "hal:local", name: "Local", transport: .speaker, backend: .coreAudio(uid: "local"))
        let stream = AudioDevice(id: "hal:captured-stream", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: "captured-stream"))
        let routes = RetainedRouteCapability.applying(
            RetainedRouteCapability(snapshot: catalogSnapshot(uid: "captured-stream")), to: []
        )
        let catalog = AudioCatalog.merge(
            hal: CoreAudioSnapshot(devices: [local, stream], currentDeviceID: local.id,
                                   systemSoundDeviceID: local.id, warnings: [],
                                   confirmedDeviceObjects: ["local": 1, "captured-stream": 2]),
            routes: PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "live held stream, endpointCount=0")
        )

        XCTAssertEqual(catalog.devices.map(\.id), [local.id, "route:bedroom"])
        XCTAssertEqual(catalog.currentDeviceID, local.id)
        XCTAssertEqual(catalog.devices.last?.isAvailable, true)
        XCTAssertEqual(routes.first?.uid, "captured-stream")
        XCTAssertEqual(routes.first?.isSelected, false)
        XCTAssertNil(catalog.warning)
    }

    func testHeldDescriptorIsNotCachedAfterItsLiveValidationExpires() {
        let ready = RetainedRouteCapability(snapshot: catalogSnapshot())
        XCTAssertEqual(RetainedRouteCapability.applying(ready, to: []).map(\.identifier), ["bedroom"])
        var stale = catalogSnapshot()["retained"] as! [String: Any]
        stale["canSelect"] = false
        stale["state"] = "invalid"
        let invalid = RetainedRouteCapability(snapshot: ["retained": stale])

        XCTAssertTrue(RetainedRouteCapability.applying(invalid, to: []).isEmpty)
        XCTAssertTrue(RetainedRouteCapability.applying(capability(id: "bedroom", ready: true), to: []).isEmpty,
                      "A previous descriptor must not survive a later sample containing only a bare handle.")
        let liveDirectory = RetainedRouteCapability.applying(invalid, to: [route(id: "bedroom", selected: false, uid: nil)])
        XCTAssertEqual(liveDirectory.map(\.identifier), ["bedroom"])
        XCTAssertFalse(liveDirectory[0].canSelect)
    }

    func testHeldDescriptorRequiresReadyUnselectedRetainedState() {
        let variants: [[String: Any]] = [
            ["canSelect": false], ["isSelected": true], ["isSelected": NSNull()], ["isSelected": NSNumber(value: 0)],
            ["state": "selected"], ["state": "invalid"], ["state": "pending"],
            ["state": "cleanupRequired"], ["state": "uncaptured"], ["state": "unavailable"],
        ]
        for variant in variants {
            var retained = catalogSnapshot()["retained"] as! [String: Any]
            retained.merge(variant) { _, new in new }
            XCTAssertTrue(RetainedRouteCapability.applying(RetainedRouteCapability(snapshot: ["retained": retained]), to: []).isEmpty,
                          "Rejected state must not create a discovery row: \(variant)")
        }
    }

    func testHeldDescriptorRejectsMalformedOrConflictingIdentityEvidence() {
        let variants: [[String: Any]] = [
            ["identifier": "other-receiver"], ["identifier": NSNull()], ["name": " \n "], ["name": 42],
            ["transport": "unknown"], ["readbackStable": false], ["readbackStable": "true"], ["readbackStable": NSNumber(value: 1)],
            ["uid": "old-capture-stream"], ["uid": ""], ["uid": 42], ["uid": ["stream"]],
        ]
        for variant in variants {
            var retained = catalogSnapshot()["retained"] as! [String: Any]
            var descriptor = retained["catalogRoute"] as! [String: Any]
            descriptor.merge(variant) { _, new in new }
            retained["catalogRoute"] = descriptor
            XCTAssertTrue(RetainedRouteCapability.applying(RetainedRouteCapability(snapshot: ["retained": retained]), to: []).isEmpty,
                          "Malformed descriptor must not create a discovery row: \(variant)")
        }
        for badAssociation: Any in ["", " \n ", 42, ["stream"]] {
            var retained = catalogSnapshot()["retained"] as! [String: Any]
            retained["associatedUID"] = badAssociation
            XCTAssertTrue(RetainedRouteCapability.applying(RetainedRouteCapability(snapshot: ["retained": retained]), to: []).isEmpty)
        }
        var retained = catalogSnapshot(uid: "current-stream")["retained"] as! [String: Any]
        var descriptor = retained["catalogRoute"] as! [String: Any]
        descriptor["uid"] = "different-stream"
        retained["catalogRoute"] = descriptor
        XCTAssertTrue(RetainedRouteCapability.applying(RetainedRouteCapability(snapshot: ["retained": retained]), to: []).isEmpty)
        descriptor.removeValue(forKey: "uid")
        retained["catalogRoute"] = descriptor
        retained["associatedUID"] = NSNull()
        XCTAssertTrue(RetainedRouteCapability.applying(RetainedRouteCapability(snapshot: ["retained": retained]), to: []).isEmpty,
                      "A missing UID is not a verified empty aggregate.")
    }

    func testHeldDescriptorCannotAddARowAgainstConflictingCurrentDirectoryEvidence() {
        let retained = RetainedRouteCapability(snapshot: catalogSnapshot(uid: "captured-stream"))
        let conflicts = [
            route(id: "other", selected: true, uid: "other-stream"),
            PrivateAudioRoute(identifier: "other", name: "Other", uid: nil, isSelected: true, canSelect: false, transport: "unknown"),
            route(id: "other", selected: false, uid: "captured-stream"),
            PrivateAudioRoute(identifier: "bedroom", name: "Current identity", uid: "different-stream", isSelected: false,
                              canSelect: false, transport: "unknown"),
        ]
        for live in conflicts {
            let result = RetainedRouteCapability.applying(retained, to: [live])
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].identifier, live.identifier)
            XCTAssertEqual(result[0].name, live.name)
            XCTAssertEqual(result[0].uid, live.uid)
        }
    }

    func testSelectedReceiverKeepsOneStableRowAfterLeavingItsSurvivingStream() {
        let streamUID = "captured-stream"
        let local = AudioDevice(id: "hal:local", name: "Local", transport: .speaker, backend: .coreAudio(uid: "local"))
        let stream = AudioDevice(id: "hal:\(streamUID)", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: streamUID))
        let selectedRoutes = RetainedRouteCapability.applying(capability(id: "bedroom", ready: true), to: [
            route(id: "bedroom", selected: true, uid: streamUID),
        ])
        let before = AudioCatalog.merge(
            hal: CoreAudioSnapshot(devices: [local, stream], currentDeviceID: stream.id,
                                   systemSoundDeviceID: local.id, warnings: []),
            routes: PrivateRouteSnapshot(routes: selectedRoutes, warning: nil, diagnostics: "selected fixture")
        )
        let localRoutes = RetainedRouteCapability.applying(
            capability(id: "bedroom", ready: true, associatedUID: streamUID),
            to: [route(id: "bedroom", selected: false, uid: nil)]
        )
        let after = AudioCatalog.merge(
            hal: CoreAudioSnapshot(devices: [local, stream], currentDeviceID: local.id,
                                   systemSoundDeviceID: local.id, warnings: []),
            routes: PrivateRouteSnapshot(routes: localRoutes, warning: nil, diagnostics: "live retained association fixture")
        )

        XCTAssertEqual(before.currentDeviceID, "route:bedroom")
        XCTAssertEqual(after.currentDeviceID, local.id)
        XCTAssertEqual(after.devices, before.devices, "Leaving a borrowed stream must not create a second selectable AirPlay row.")
        XCTAssertEqual(after.devices.map(\.id), [local.id, "route:bedroom"])
        XCTAssertEqual(after.devices.last?.backend, .privateRoute(identifier: "bedroom"))
        XCTAssertFalse(localRoutes[0].isSelected, "A live transport association does not claim the receiver is selected.")
        XCTAssertNil(after.warning)
    }

    func testMissingOrRejectedAssociationDoesNotHideAnUnidentifiedHALStream() {
        let local = AudioDevice(id: "hal:local", name: "Local", transport: .speaker, backend: .coreAudio(uid: "local"))
        let stream = AudioDevice(id: "hal:surviving-stream", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: "surviving-stream"))
        for retained in [nil,
                         capability(id: "bedroom", ready: true),
                         capability(id: "bedroom", ready: false, associatedUID: "surviving-stream",
                                    associationReadbackStable: false)] {
            let routes = RetainedRouteCapability.applying(retained, to: [route(id: "bedroom", selected: false, uid: nil)])
            let catalog = AudioCatalog.merge(
                hal: CoreAudioSnapshot(devices: [local, stream], currentDeviceID: local.id,
                                       systemSoundDeviceID: local.id, warnings: []),
                routes: PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "invalidated association fixture")
            )

            XCTAssertNil(routes[0].uid)
            XCTAssertEqual(Set(catalog.devices.map(\.id)), [local.id, stream.id, "route:bedroom"])
            XCTAssertEqual(catalog.currentDeviceID, local.id)
            XCTAssertEqual(catalog.devices.first(where: { $0.id == stream.id })?.name, "AirPlay")
        }
    }

    func testRetainedAssociationCannotOverwriteExplicitUIDOrSupplySelectedEvidence() {
        let retained = capability(id: "bedroom", ready: false, associatedUID: "current-stream")
        let explicit = RetainedRouteCapability.applying(retained, to: [
            route(id: "bedroom", selected: false, uid: "different-live-stream"),
        ])
        let selected = RetainedRouteCapability.applying(retained, to: [
            route(id: "bedroom", selected: true, uid: nil),
        ])

        XCTAssertEqual(explicit[0].uid, "different-live-stream", "Current explicit identity must win over retained association evidence.")
        XCTAssertFalse(explicit[0].isSelected)
        XCTAssertNil(selected[0].uid, "An unselected retained association must not complete another sample's selected evidence.")
        XCTAssertTrue(selected[0].isSelected)
    }

    func testVerifiedAssociationSurvivesRejectedSwitchCapabilityWithoutCreatingAnUndiscoveredRow() {
        var held = catalogSnapshot(uid: "replacement-stream")["retained"] as! [String: Any]
        held["canSelect"] = false
        held["state"] = "invalid"
        held["reason"] = "The original captured stream has changed"
        let retained = RetainedRouteCapability(snapshot: ["retained": held])
        let result = RetainedRouteCapability.applying(retained, to: [route(id: "bedroom", selected: false, uid: nil)])

        XCTAssertEqual(retained?.associatedUID, "replacement-stream")
        XCTAssertEqual(result[0].uid, "replacement-stream", "Fresh identity remains usable when the original stream can no longer be selected.")
        XCTAssertFalse(result[0].canSelect)
        XCTAssertFalse(result[0].isSelected)
        XCTAssertEqual(result[0].unavailableReason, "The original captured stream has changed")
        XCTAssertNil(retained?.validatedUnselectedRoute)
        XCTAssertTrue(RetainedRouteCapability.applying(retained, to: []).isEmpty)
    }

    func testRetainedAssociationRequiresAnExplicitStrictReadbackFlagRegardlessOfCapability() {
        let rejectedFlags: [Any?] = [nil, NSNull(), false, "true", NSNumber(value: 1), NSNumber(value: 0), [true]]
        for ready in [false, true] {
            for flag in rejectedFlags {
                var held: [String: Any] = ["identifier": "bedroom", "canSelect": ready,
                                           "associatedUID": "current-stream"]
                if let flag { held["associationReadbackStable"] = flag }
                let retained = RetainedRouteCapability(snapshot: ["retained": held])
                let result = RetainedRouteCapability.applying(retained, to: [route(id: "bedroom", selected: false, uid: nil)])

                XCTAssertNil(retained?.associatedUID, "An absent or malformed flag cannot authenticate the UID: \(String(describing: flag))")
                XCTAssertNil(result[0].uid)
                XCTAssertEqual(result[0].canSelect, ready, "Association validation does not manufacture or revoke separate switch evidence.")
            }
        }
    }

    func testHeldStreamDescriptorCannotUseAnUnverifiedAssociation() {
        for flag: Any? in [nil, NSNull(), false, "true", NSNumber(value: 1)] {
            var held = catalogSnapshot(uid: "current-stream")["retained"] as! [String: Any]
            held["associationReadbackStable"] = flag
            let retained = RetainedRouteCapability(snapshot: ["retained": held])

            XCTAssertNil(retained?.validatedUnselectedRoute)
            XCTAssertTrue(RetainedRouteCapability.applying(retained, to: []).isEmpty)
        }
    }

    func testMalformedAssociatedUIDCannotBindAReceiverToHAL() {
        for value: Any in [NSNull(), "", " \n ", 42, ["captured-stream"]] {
            let retained = RetainedRouteCapability(snapshot: ["retained": [
                "identifier": "bedroom", "canSelect": true, "associatedUID": value,
                "associationReadbackStable": true,
            ]])
            let result = RetainedRouteCapability.applying(retained, to: [route(id: "bedroom", selected: false, uid: nil)])

            XCTAssertTrue(result[0].canSelect)
            XCTAssertNil(result[0].uid)
        }
    }

    func testOldSelectedFlagAndWritableHALCannotGrantMissingOrRejectedCapability() {
        let staleSelected = route(id: "bedroom", selected: true, uid: "old-stream")
        let local = AudioDevice(id: "hal:local", name: "Local", transport: .speaker, backend: .coreAudio(uid: "local"))
        let transport = AudioDevice(id: "hal:old-stream", name: "AirPlay", transport: .airplay,
                                    backend: .coreAudio(uid: "old-stream"))
        for retained in [nil, capability(id: "bedroom", ready: false)] {
            let routes = RetainedRouteCapability.applying(retained, to: [staleSelected])
            XCTAssertFalse(routes[0].canSelect)
            XCTAssertTrue(routes[0].isSelected, "Capability validation must not rewrite independently collected selection evidence.")
            let catalog = AudioCatalog.merge(
                hal: CoreAudioSnapshot(devices: [local, transport], currentDeviceID: local.id,
                                       systemSoundDeviceID: local.id, warnings: []),
                routes: PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "unit-test fixture")
            )

            XCTAssertEqual(catalog.devices.first(where: { $0.id == "route:bedroom" })?.isAvailable, false)
            XCTAssertNil(catalog.currentDeviceID, "A stale private selected flag must not override the current local HAL output.")
        }
    }

    func testRejectedCapabilityPreservesItsReasonAndDoesNotAlterCurrentAssociation() {
        let retained = RetainedRouteCapability(snapshot: ["retained": [
            "identifier": "bedroom", "canSelect": false, "reason": "The live leaf is no longer eligible",
        ]])
        let result = RetainedRouteCapability.applying(retained, to: [route(id: "bedroom", selected: true, uid: "current-stream")])

        XCTAssertFalse(result[0].canSelect)
        XCTAssertEqual(result[0].unavailableReason, "The live leaf is no longer eligible")
        XCTAssertTrue(result[0].isSelected)
        XCTAssertEqual(result[0].uid, "current-stream")
    }

    func testMalformedRetainedEvidenceCannotGrantCapability() {
        for value: Any in [NSNull(), [:], ["identifier": "", "canSelect": true],
                           ["identifier": "bedroom"], ["identifier": "bedroom", "canSelect": "true"]] {
            XCTAssertNil(RetainedRouteCapability(snapshot: ["retained": value]))
        }
    }

    private func capability(id: String, ready: Bool, associatedUID: String? = nil,
                            associationReadbackStable: Bool = true) -> RetainedRouteCapability? {
        var retained: [String: Any] = ["identifier": id, "canSelect": ready]
        if let associatedUID {
            retained["associatedUID"] = associatedUID
            retained["associationReadbackStable"] = associationReadbackStable
        }
        return RetainedRouteCapability(snapshot: ["retained": retained])
    }

    private func catalogSnapshot(uid: String? = nil) -> [String: Any] {
        ["retained": [
            "identifier": "bedroom", "canSelect": true, "state": "retained", "isSelected": false,
            "associatedUID": uid as Any? ?? NSNull(),
            "associationReadbackStable": uid != nil,
            "catalogRoute": ["identifier": "bedroom", "name": "Bedroom", "transport": "airplay",
                             "uid": uid as Any? ?? NSNull(), "readbackStable": true],
        ]]
    }

    private func route(id: String, selected: Bool, uid: String?) -> PrivateAudioRoute {
        PrivateAudioRoute(identifier: id, name: "Bedroom", uid: uid, isSelected: selected,
                          canSelect: true, transport: "airplay")
    }
}
