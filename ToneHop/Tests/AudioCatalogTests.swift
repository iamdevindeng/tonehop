import XCTest
@testable import ToneHop

final class AudioCatalogTests: XCTestCase {
    func testSameNameWithDifferentIdentitiesDoesNotMerge() {
        let speaker = device(uid: "local-a", name: "Shared name")
        let hal = snapshot(devices: [speaker], current: speaker.id)
        let routes = routeSnapshot([
            route(id: "network-a", name: "Shared name"),
            route(id: "network-b", name: "Shared name"),
        ])

        let catalog = AudioCatalog.merge(hal: hal, routes: routes)

        XCTAssertEqual(catalog.devices.count, 3)
        XCTAssertEqual(Set(catalog.devices.map(\.id)), ["hal:local-a", "route:network-a", "route:network-b"])
        XCTAssertEqual(catalog.devices.map(\.name), ["Shared name", "Shared name", "Shared name"])
        XCTAssertEqual(catalog.currentDeviceID, speaker.id)
    }

    func testExplicitSharedUIDKeepsReceiverIdentityAndPrivateBackend() {
        let airplay = device(uid: "airplay-device-uid", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [airplay], current: airplay.id),
            routes: routeSnapshot([route(id: "route-identifier", name: "Bedroom", uid: "airplay-device-uid", selected: true)])
        )

        XCTAssertEqual(catalog.devices.count, 1)
        XCTAssertEqual(catalog.devices.first?.id, "route:route-identifier")
        XCTAssertEqual(catalog.devices.first?.name, "Bedroom")
        XCTAssertEqual(catalog.devices.first?.backend, .privateRoute(identifier: "route-identifier"))
        XCTAssertEqual(catalog.currentDeviceID, "route:route-identifier")
    }

    func testWritableHALCannotEnableAnUnselectablePrivateReceiver() {
        let airplay = device(uid: "aggregate-stream", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [airplay], current: airplay.id),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: "aggregate-stream",
                                         selected: true, canSelect: false)])
        )

        XCTAssertEqual(catalog.devices.count, 1)
        XCTAssertEqual(catalog.devices.first?.backend, .privateRoute(identifier: "bedroom"))
        XCTAssertEqual(catalog.devices.first?.isAvailable, false)
        XCTAssertNotNil(catalog.devices.first?.unavailableReason)
        XCTAssertEqual(catalog.currentDeviceID, "route:bedroom", "Selection evidence is independent of whether the app can switch back to this receiver.")
    }

    func testUnassociatedHALStreamCannotBypassReceiverValidationDuringDiscovery() {
        let local = device(uid: "local", name: "Mac mini Speakers")
        let airplay = device(uid: "aggregate-stream", name: "AirPlay", transport: .airplay)
        for routes in [[], [route(id: "bedroom", name: "Bedroom", canSelect: false)]] {
            let catalog = AudioCatalog.merge(
                hal: snapshot(devices: [local, airplay], current: local.id),
                routes: routeSnapshot(routes))
            let transport = catalog.devices.first { $0.id == airplay.id }

            XCTAssertEqual(transport?.name, "AirPlay")
            XCTAssertEqual(transport?.backend, airplay.backend, "Identity stays available for a later exact association.")
            XCTAssertEqual(transport?.isAvailable, false)
            XCTAssertEqual(transport?.unavailableReason, expectedLocalized("Confirming the AirPlay receiver. Select the device in the macOS Sound menu.", "正在确认 AirPlay 接收器，请在 macOS「声音」菜单中选择目标设备。"))
            XCTAssertEqual(catalog.currentDeviceID, local.id)
            XCTAssertEqual(catalog.devices.first { $0.id == local.id }, local)
        }
    }

    func testUnassociatedCurrentHALStreamKeepsActualSelectionWhileDisabled() {
        let airplay = device(uid: "aggregate-stream", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [airplay], current: airplay.id),
            routes: routeSnapshot([]))

        XCTAssertEqual(catalog.devices.map(\.id), [airplay.id])
        XCTAssertEqual(catalog.currentDeviceID, airplay.id)
        XCTAssertFalse(catalog.devices[0].isAvailable)
    }

    func testFreshExactAssociationReplacesDisabledTransportWithOneReceiverRow() {
        let local = device(uid: "local", name: "Mac mini Speakers")
        let airplay = device(uid: "aggregate-stream", name: "AirPlay", transport: .airplay)
        for canSelect in [false, true] {
            let catalog = AudioCatalog.merge(
                hal: snapshot(devices: [local, airplay], current: local.id),
                routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: "aggregate-stream", canSelect: canSelect)]))

            XCTAssertEqual(catalog.devices.map(\.id), [local.id, "route:bedroom"])
            XCTAssertEqual(catalog.devices[1].isAvailable, canSelect)
            XCTAssertEqual(catalog.devices[1].backend, .privateRoute(identifier: "bedroom"))
            XCTAssertEqual(catalog.currentDeviceID, local.id)
            XCTAssertNil(catalog.warning)
        }
    }

    func testReceiverIdentitySurvivesTransportReplacementAndDisappearance() {
        let oldStream = device(uid: "aggregate-old-stream", name: "AirPlay", transport: .airplay)
        let newStream = device(uid: "aggregate-new-stream", name: "AirPlay", transport: .airplay)
        let first = AudioCatalog.merge(
            hal: snapshot(devices: [oldStream], current: oldStream.id),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: "aggregate-old-stream", selected: true)])
        )
        let recreated = AudioCatalog.merge(
            hal: snapshot(devices: [newStream], current: newStream.id),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: "aggregate-new-stream", selected: true)])
        )
        let disconnected = AudioCatalog.merge(
            hal: snapshot(devices: [], current: nil),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", canSelect: false)])
        )

        XCTAssertEqual(first.devices, recreated.devices)
        XCTAssertEqual(first.currentDeviceID, recreated.currentDeviceID)
        XCTAssertEqual(disconnected.devices.first?.id, first.devices.first?.id)
        XCTAssertEqual(disconnected.devices.first?.backend, first.devices.first?.backend)
        XCTAssertNil(disconnected.currentDeviceID)
    }

    func testMatchedDefaultHALDoesNotInventPrivateSelectedEvidence() {
        let airplay = device(uid: "aggregate-stream", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [airplay], current: airplay.id),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: "aggregate-stream")])
        )

        XCTAssertEqual(catalog.devices.map(\.id), ["route:bedroom"])
        XCTAssertNil(catalog.currentDeviceID)
        XCTAssertTrue(catalog.warning?.contains(expectedLocalized("system output do not yet match", "系统默认输出尚未一致")) == true)
    }

    func testAssociationDoesNotMoveSelectionAwayFromTheCurrentLocalDevice() {
        let speaker = device(uid: "local-a", name: "Local output")
        let airplay = device(uid: "aggregate-stream", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [speaker, airplay], current: speaker.id),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: "aggregate-stream", canSelect: false)])
        )

        XCTAssertEqual(catalog.devices.map(\.id), [speaker.id, "route:bedroom"])
        XCTAssertEqual(catalog.currentDeviceID, speaker.id)
        XCTAssertNil(catalog.warning)
    }

    func testExplicitUIDMismatchCannotFallBackToAirPlayTransportSelection() {
        let airplay = device(uid: "different-stream", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [airplay], current: airplay.id),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: "aggregate-stream", selected: true)])
        )

        XCTAssertEqual(catalog.devices.count, 2)
        XCTAssertNil(catalog.currentDeviceID)
        XCTAssertTrue(catalog.warning?.contains(expectedLocalized("system output do not yet match", "系统默认输出尚未一致")) == true)
    }

    func testSharedUIDMustMatchTheDefaultDeviceEvenWhenBothOutputsAreAirPlay() {
        let bedroom = device(uid: "bedroom-stream", name: "AirPlay", transport: .airplay)
        let other = device(uid: "other-stream", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [bedroom, other], current: other.id),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: "bedroom-stream", selected: true)])
        )

        XCTAssertEqual(Set(catalog.devices.map(\.id)), ["route:bedroom", other.id])
        XCTAssertNil(catalog.currentDeviceID)
        XCTAssertNotNil(catalog.warning)
    }

    func testRouteWithoutSharedUIDCannotRenameOrMergeHALDevice() {
        let airplay = device(uid: "airplay-device-uid", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [airplay], current: airplay.id),
            routes: routeSnapshot([route(id: "route-identifier", name: "Bedroom")])
        )

        XCTAssertEqual(catalog.devices.count, 2)
        XCTAssertEqual(catalog.devices.first(where: { $0.id == airplay.id })?.name, "AirPlay")
        XCTAssertEqual(catalog.devices.first(where: { $0.id == "route:route-identifier" })?.name, "Bedroom")
        XCTAssertEqual(catalog.currentDeviceID, airplay.id)
    }

    func testConflictingSelectedRoutesDoNotGuessCurrentOutput() {
        let speaker = device(uid: "local-a", name: "Local output")
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [speaker], current: speaker.id),
            routes: routeSnapshot([
                route(id: "network-a", name: "First receiver", selected: true),
                route(id: "network-b", name: "Second receiver", selected: true),
            ])
        )

        XCTAssertNil(catalog.currentDeviceID)
        XCTAssertNotNil(catalog.warning)
        XCTAssertTrue(catalog.warning?.contains(expectedLocalized("multiple selected routes", "多个已选路由")) == true)
        XCTAssertEqual(catalog.devices.count, 3)
    }

    func testDuplicatePrivateIdentityIsExcludedInsteadOfPickingFirstMatch() {
        let speaker = device(uid: "local-a", name: "Local output")
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [speaker], current: speaker.id),
            routes: routeSnapshot([
                route(id: "duplicate", name: "First receiver"),
                route(id: "duplicate", name: "Second receiver"),
            ])
        )

        XCTAssertEqual(catalog.devices, [speaker])
        XCTAssertTrue(catalog.warning?.contains(expectedLocalized("cannot be identified", "身份不明确")) == true)
    }

    func testSelectedNetworkRouteDoesNotOverrideConflictingLocalHALOutput() {
        let speaker = device(uid: "local-a", name: "Local output")
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [speaker], current: speaker.id),
            routes: routeSnapshot([route(id: "network-a", name: "Bedroom", selected: true)])
        )

        XCTAssertNil(catalog.currentDeviceID, "A private selected flag alone must not confirm a system output switch.")
        XCTAssertTrue(catalog.warning?.contains(expectedLocalized("system output do not yet match", "系统默认输出尚未一致")) == true)
        XCTAssertEqual(catalog.devices.count, 2)
    }

    func testSelectedNetworkRouteRequiresReadableHALOutput() {
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [], current: nil),
            routes: routeSnapshot([route(id: "network-a", name: "Bedroom", selected: true)])
        )

        XCTAssertNil(catalog.currentDeviceID)
        XCTAssertNotNil(catalog.warning)
    }

    func testSelectedRouteWithoutUIDCannotBeConfirmedByHALAirPlayTransport() {
        let speaker = device(uid: "local-a", name: "Local output")
        let airplay = device(uid: "airplay-a", name: "AirPlay", transport: .airplay)
        // A source claim without a complete UID cannot identify which AirPlay
        // receiver is carrying the default output, even with one discovery row.
        let systemSelectedRoutes = routeSnapshot([
            PrivateAudioRoute(identifier: "system-selected-route", name: "Bedroom", uid: nil,
                              isSelected: true, canSelect: true, transport: "unknown"),
        ])

        let confirmed = AudioCatalog.merge(
            hal: snapshot(devices: [speaker, airplay], current: airplay.id),
            routes: systemSelectedRoutes
        )
        XCTAssertNil(confirmed.currentDeviceID)
        XCTAssertTrue(confirmed.warning?.contains(expectedLocalized("system output do not yet match", "系统默认输出尚未一致")) == true)
        XCTAssertEqual(confirmed.devices.count, 3, "Without a shared UID, route and HAL records remain distinct.")
        XCTAssertEqual(confirmed.devices.first(where: { $0.id == airplay.id })?.name, "AirPlay")

        let conflicting = AudioCatalog.merge(
            hal: snapshot(devices: [speaker, airplay], current: speaker.id),
            routes: systemSelectedRoutes
        )
        XCTAssertNil(conflicting.currentDeviceID, "A selected private route must not override a conflicting local HAL output.")
        XCTAssertTrue(conflicting.warning?.contains(expectedLocalized("system output do not yet match", "系统默认输出尚未一致")) == true)
    }

    func testDifferentRoutesClaimingSameHALUIDDoNotOverwriteItsName() {
        let airplay = device(uid: "shared-hal-uid", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [airplay], current: airplay.id),
            routes: routeSnapshot([
                route(id: "network-a", name: "Bedroom", uid: "shared-hal-uid", selected: true),
                route(id: "network-b", name: "Living Room", uid: "shared-hal-uid"),
            ])
        )

        XCTAssertEqual(catalog.devices.map(\.id), [airplay.id], "An ambiguous identity association must preserve the HAL record.")
        XCTAssertEqual(catalog.devices[0].name, airplay.name)
        XCTAssertEqual(catalog.devices[0].backend, airplay.backend)
        XCTAssertFalse(catalog.devices[0].isAvailable)
        XCTAssertEqual(catalog.currentDeviceID, airplay.id)
        XCTAssertTrue(catalog.warning?.contains(expectedLocalized("Multiple network targets match the same system device", "多个网络目标对应同一系统设备")) == true)
    }

    func testDuplicateHALUIDCannotChooseWhichTransportToMerge() {
        let first = device(uid: "shared-stream", name: "AirPlay", transport: .airplay)
        let second = AudioDevice(id: "hal:duplicate-record", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: "shared-stream"))
        let catalog = AudioCatalog.merge(
            hal: snapshot(devices: [first, second], current: first.id),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: "shared-stream", selected: true)])
        )

        XCTAssertEqual(catalog.devices.count, 3)
        XCTAssertEqual(catalog.devices.filter { $0.backend == .coreAudio(uid: "shared-stream") }.count, 2)
        XCTAssertNil(catalog.currentDeviceID)
        XCTAssertTrue(catalog.warning?.contains(expectedLocalized("Multiple system devices match the same network target", "多个系统设备对应同一网络目标")) == true)
    }

    func testEmptyUIDAndSharedPrefixCannotAssociateReceivers() {
        let airplay = device(uid: "aggregate-stream-Audio", name: "Bedroom", transport: .airplay)
        for uid in ["", "aggregate-stream"] {
            let catalog = AudioCatalog.merge(
                hal: snapshot(devices: [airplay], current: airplay.id),
                routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", uid: uid)])
            )

            XCTAssertEqual(catalog.devices.count, 2)
            let unresolved = catalog.devices.first(where: { $0.id == airplay.id })
            XCTAssertEqual(unresolved?.name, airplay.name)
            XCTAssertEqual(unresolved?.backend, airplay.backend)
            XCTAssertEqual(unresolved?.isAvailable, false)
        }
    }

    func testUnconfirmedTransportRemainsImmediatelyVisibleBesideReceiver() {
        let local = device(uid: "local", name: "Speakers")
        let stream = device(uid: "new-stream", name: "AirPlay", transport: .airplay)
        let catalog = AudioCatalog.merge(hal: snapshot(devices: [local, stream], current: stream.id),
            routes: routeSnapshot([route(id: "bedroom", name: "Bedroom", canSelect: false)]))

        XCTAssertEqual(catalog.devices.map(\.id), [local.id, stream.id, "route:bedroom"])
        XCTAssertEqual(catalog.currentDeviceID, stream.id)
        XCTAssertFalse(catalog.devices[1].isAvailable)
        XCTAssertFalse(catalog.devices[2].isAvailable)
    }

    func testIncompleteDiscoveryKeepsPreviousReceiverDisabledWithoutShortcutCapability() {
        let old = AudioDevice(id: "route:receiver", name: "Bedroom", transport: .airplay,
            backend: .privateRoute(identifier: "receiver"), shortcutTarget: .receiver(identifier: "receiver"))
        let catalog = AudioCatalog(devices: [], currentDeviceID: nil, warning: nil)
            .preservingUnconfirmedDevices(from: [old], discovery: .unconfirmed)

        XCTAssertEqual(catalog.devices.map(\.id), [old.id])
        XCTAssertFalse(catalog.devices[0].isAvailable)
        XCTAssertNil(catalog.devices[0].shortcutTarget)
        XCTAssertTrue(catalog.devices[0].represents(.receiver(identifier: "receiver")))
        XCTAssertNil(catalog.currentDeviceID)
    }

    func testCompleteMissingReceiverIsRemovedEvenIfRetainedCapabilityStillExists() {
        var privateSnapshot = routeSnapshot([route(id: "old", name: "Old retained receiver")])
        privateSnapshot.discovery = .init(isComplete: true)
        let hal = CoreAudioSnapshot(devices: [], currentDeviceID: nil, systemSoundDeviceID: nil, warnings: [],
            discovery: .init(isComplete: true), isOutputInventoryComplete: true)
        let old = AudioDevice(id: "route:old", name: "Old retained receiver", transport: .airplay,
            backend: .privateRoute(identifier: "old"))
        let inventory = AudioDiscoveryInventory.merge(hal: hal, routes: privateSnapshot)
        let catalog = AudioCatalog.merge(hal: hal, routes: privateSnapshot)
            .preservingUnconfirmedDevices(from: [old], discovery: inventory)

        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "old")), .missing)
        XCTAssertTrue(catalog.devices.isEmpty)
    }

    func testUnconfirmedRetainedCapabilityCannotEnableReceiver() {
        var privateSnapshot = routeSnapshot([route(id: "old", name: "Bedroom")])
        privateSnapshot.discovery = .unconfirmed
        privateSnapshot.confirmedShortcutIdentifiers = ["old"]
        let catalog = AudioCatalog.merge(hal: snapshot(devices: [], current: nil), routes: privateSnapshot)
        XCTAssertEqual(catalog.devices.count, 1)
        XCTAssertFalse(catalog.devices[0].isAvailable)
        XCTAssertNil(catalog.devices[0].shortcutTarget)
    }

    func testObservedReceiverWithBindingConflictPreservesIndependentLiveSwitchCapability() {
        var privateSnapshot = routeSnapshot([route(id: "receiver", name: "Receiver")])
        privateSnapshot.discovery = .init(observedIdentifiers: ["receiver"],
            conflictedIdentifiers: ["receiver"], isComplete: true)
        privateSnapshot.confirmedShortcutIdentifiers = []
        let hal = snapshot(devices: [], current: nil)
        let inventory = AudioDiscoveryInventory.merge(hal: hal, routes: privateSnapshot)
        let catalog = AudioCatalog.merge(hal: hal, routes: privateSnapshot)

        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "receiver")), .found)
        XCTAssertEqual(inventory.presence(of: .receiver(identifier: "other")), .unconfirmed)
        XCTAssertEqual(catalog.devices.count, 1)
        XCTAssertTrue(catalog.devices[0].isAvailable, "Binding uniqueness must not revoke a separately proven live route capability.")
        XCTAssertNil(catalog.devices[0].shortcutTarget)
    }

    func testPublicHALSpeakersUSBAndConnectedBluetoothStayOnCommonBackend() {
        let devices = [device(uid: "local", name: "Speakers"),
            device(uid: "usb", name: "USB", transport: .usb),
            device(uid: "bluetooth", name: "Headphones", transport: .bluetooth)]
        let catalog = AudioCatalog.merge(hal: snapshot(devices: devices, current: devices[0].id),
            routes: .init(routes: [], warning: nil, diagnostics: "private discovery failed"))
        XCTAssertEqual(catalog.devices, devices)
        XCTAssertTrue(catalog.devices.allSatisfy(\.isAvailable))
        XCTAssertEqual(catalog.currentDeviceID, devices[0].id)
    }

    func testCatalogPreservesSystemAndUserDeviceNamesAcrossAppLanguages() {
        let names = ["Bedroom", "Mac mini扬声器", "取消", "Café 🎧 %@"]
        let local = names.enumerated().map { device(uid: "local-\($0.offset)", name: $0.element) }
        let network = names.enumerated().map { route(id: "receiver-\($0.offset)", name: $0.element) }
        let catalog = AudioCatalog.merge(hal: snapshot(devices: local, current: local[0].id),
                                         routes: routeSnapshot(network))

        for (index, name) in names.enumerated() {
            XCTAssertEqual(catalog.devices.first { $0.id == "hal:local-\(index)" }?.name, name)
            XCTAssertEqual(catalog.devices.first { $0.id == "route:receiver-\(index)" }?.name, name)
        }
        XCTAssertEqual(catalog.currentDeviceID, local[0].id)
    }

    private func device(uid: String, name: String, transport: AudioTransport = .speaker) -> AudioDevice {
        AudioDevice(id: "hal:\(uid)", name: name, transport: transport, backend: .coreAudio(uid: uid))
    }

    private func snapshot(devices: [AudioDevice], current: String?) -> CoreAudioSnapshot {
        CoreAudioSnapshot(devices: devices, currentDeviceID: current, systemSoundDeviceID: current, warnings: [])
    }

    private func route(id: String, name: String, uid: String? = nil, selected: Bool = false,
                       canSelect: Bool = true) -> PrivateAudioRoute {
        PrivateAudioRoute(identifier: id, name: name, uid: uid, isSelected: selected, canSelect: canSelect, transport: "airplay")
    }

    private func routeSnapshot(_ routes: [PrivateAudioRoute]) -> PrivateRouteSnapshot {
        PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "unit-test fixture",
            discovery: .init(observedIdentifiers: Set(routes.map(\.identifier)), isComplete: true))
    }
}
