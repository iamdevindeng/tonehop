import AppKit
import Foundation
import XCTest
@testable import ToneHop

@MainActor
final class AudioInteractionBoundaryTests: XCTestCase {
    func testActualQuitMenuConflictsWithCurrentLayoutCommandQOnly() throws {
        let quitKey = try currentLayoutLetterKey { $0 == "Q" }
        let otherKey = try currentLayoutLetterKey { $0 != "Q" }
        let quitMenu = StatusBarController.makeQuitMenu()
        let quitShortcut = try DeviceShortcut(keyCode: quitKey.code, modifiers: .command)
        let otherShortcut = try DeviceShortcut(keyCode: otherKey.code, modifiers: .command)
        let controlQuit = try DeviceShortcut(keyCode: quitKey.code, modifiers: .control)

        XCTAssertEqual(StatusBarController.shortcutConflict(
            quitShortcut, quitMenu: quitMenu, mainMenu: nil), expectedLocalized("Quit", "退出"))
        XCTAssertNil(StatusBarController.shortcutConflict(
            otherShortcut, quitMenu: quitMenu, mainMenu: nil))
        XCTAssertNil(StatusBarController.shortcutConflict(
            controlQuit, quitMenu: quitMenu, mainMenu: nil))
    }

    func testMenuConflictReadsMainSubmenuAndLiveStatusMenuChanges() throws {
        let key = try currentLayoutLetterKey { $0 != "Q" }
        let shortcut = try DeviceShortcut(keyCode: key.code, modifiers: .command)
        let submenuShortcut = try DeviceShortcut(keyCode: key.code, modifiers: .control)
        let quitMenu = StatusBarController.makeQuitMenu()
        let mainMenu = NSMenu()
        let parentItem = NSMenuItem(title: "测试菜单", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let childItem = NSMenuItem(title: "子菜单操作", action: nil, keyEquivalent: key.letter.lowercased())
        childItem.keyEquivalentModifierMask = .control
        submenu.addItem(childItem)
        parentItem.submenu = submenu
        mainMenu.addItem(parentItem)

        XCTAssertEqual(StatusBarController.shortcutConflict(
            submenuShortcut, quitMenu: quitMenu, mainMenu: mainMenu), "子菜单操作")
        XCTAssertNil(StatusBarController.shortcutConflict(
            shortcut, quitMenu: quitMenu, mainMenu: mainMenu))

        let quitItem = try XCTUnwrap(quitMenu.items.first)
        quitItem.keyEquivalent = key.letter.lowercased()
        XCTAssertEqual(StatusBarController.shortcutConflict(
            shortcut, quitMenu: quitMenu, mainMenu: mainMenu), expectedLocalized("Quit", "退出"),
            "Validation must inspect the supplied status menu instead of a separately rebuilt menu.")
        quitMenu.removeItem(quitItem)
        XCTAssertNil(StatusBarController.shortcutConflict(
            shortcut, quitMenu: quitMenu, mainMenu: mainMenu))
        XCTAssertEqual(StatusBarController.shortcutConflict(
            submenuShortcut, quitMenu: quitMenu, mainMenu: mainMenu), "子菜单操作")
    }

    func testEscapePassesToNativeModalRegardlessOfPopoverOrRecordingState() {
        for isPopoverWindow in [false, true] {
            for isRecording in [false, true] {
                for hasModifiers in [false, true] {
                    XCTAssertEqual(PopoverEscapeRouting.action(
                        isPopoverWindow: isPopoverWindow, hasModalWindow: true,
                        isRecording: isRecording, hasModifiers: hasModifiers), .passThrough,
                        "A native alert must receive Escape without first cancelling recording or closing its background popover.")
                }
            }
        }
    }

    func testEscapeInAnotherWindowDoesNotCancelRecordingOrClosePopover() {
        for isRecording in [false, true] {
            for hasModifiers in [false, true] {
                XCTAssertEqual(PopoverEscapeRouting.action(
                    isPopoverWindow: false, hasModalWindow: false,
                    isRecording: isRecording, hasModifiers: hasModifiers), .passThrough)
            }
        }
    }

    func testPopoverEscapeCancelsRecordingBeforeClosingAndPreservesModifiedRecordingInput() {
        XCTAssertEqual(PopoverEscapeRouting.action(
            isPopoverWindow: true, hasModalWindow: false, isRecording: true, hasModifiers: false),
            .cancelRecording)
        XCTAssertEqual(PopoverEscapeRouting.action(
            isPopoverWindow: true, hasModalWindow: false, isRecording: true, hasModifiers: true),
            .passThrough, "A modified Escape must reach the recorder's combination validation.")
        XCTAssertEqual(PopoverEscapeRouting.action(
            isPopoverWindow: true, hasModalWindow: false, isRecording: false, hasModifiers: false),
            .closePopover, "After recording ends, ordinary Escape resumes closing the popover.")
    }

    func testCancelledPermitRejectsNewWritesWithoutClosingSharedGate() async {
        let signal = AudioShutdownSignal()
        let cancelled = AudioMutationPermit()
        cancelled.cancel()
        cancelled.cancel()

        XCTAssertFalse(signal.performIfRunning(permit: cancelled) {
            XCTFail("A paused interaction must not register another system write.")
        })
        XCTAssertFalse(signal.isShuttingDown, "Pausing volume must leave other audio operations running.")
        XCTAssertTrue(signal.performIfRunning(permit: AudioMutationPermit()) {})
        await signal.drainSubmissions()
        XCTAssertFalse(signal.performIfRunning(permit: cancelled) {
            XCTFail("Draining or admitting a new generation must not revive the cancelled permit.")
        })
    }

    func testFreshPermitCannotBypassClosedShutdownGate() async {
        let signal = AudioShutdownSignal()
        signal.begin()

        XCTAssertFalse(signal.performIfRunning(permit: AudioMutationPermit()) {
            XCTFail("A new interaction generation cannot reopen the shutdown gate.")
        })
        await signal.drainSubmissions()
    }

    func testCancellingPermitDoesNotRevokeAcceptedWriteOrReleaseDrainEarly() async {
        let signal = AudioShutdownSignal()
        let permit = AudioMutationPermit()
        let trace = InteractionSubmissionTrace()
        let entered = XCTestExpectation(description: "registered operation entered")
        let returned = XCTestExpectation(description: "registered operation returned")
        let drained = XCTestExpectation(description: "drain observed actual operation return")
        let prematureDrain = XCTestExpectation(description: "drain cannot complete while native operation is held")
        prematureDrain.isInverted = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let work = Task.detached {
            let accepted = signal.performIfRunning(permit: permit) {
                trace.record("entered")
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
                trace.record("returned")
            }
            returned.fulfill()
            return accepted
        }
        let admission = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(admission, .completed)
        permit.cancel()
        work.cancel()
        XCTAssertFalse(signal.performIfRunning(permit: permit) {
            XCTFail("Permit cancellation must reject writes queued behind the accepted operation.")
        })

        let waiter = Task {
            await signal.drainSubmissions()
            if !trace.values().contains("returned") { prematureDrain.fulfill() }
            trace.record("drained")
            drained.fulfill()
        }
        waiter.cancel()
        let held = await XCTWaiter.fulfillment(of: [prematureDrain], timeout: 0.05)
        XCTAssertEqual(held, .completed)
        XCTAssertEqual(trace.values(), ["entered"])

        release.signal()
        let completion = await XCTWaiter.fulfillment(of: [returned, drained], timeout: 2)
        XCTAssertEqual(completion, .completed)
        let accepted = await work.value
        XCTAssertTrue(accepted, "Cancellation cannot retroactively undo an accepted native write.")
        await waiter.value
        XCTAssertEqual(trace.values(), ["entered", "returned", "drained"])
        XCTAssertFalse(signal.isShuttingDown)
    }

    func testPermitCancellationRaceNeverAdmitsSubsequentWrites() async {
        for _ in 0..<25 {
            let signal = AudioShutdownSignal()
            let permit = AudioMutationPermit()
            let trace = InteractionSubmissionTrace()
            let submission = Task.detached {
                signal.performIfRunning(permit: permit) { trace.record("accepted") }
            }
            let cancellation = Task.detached { permit.cancel() }
            let accepted = await submission.value
            await cancellation.value

            XCTAssertEqual(trace.values(), accepted ? ["accepted"] : [])
            XCTAssertFalse(signal.performIfRunning(permit: permit) {
                XCTFail("No submission may register after permit cancellation has returned.")
            })
            await signal.drainSubmissions()
        }
    }

    func testRawUIDConflictSurvivesDisplayFilteringWhileOtherUniqueTargetsRemainConfirmed() {
        let visibleObject = CoreAudioObjectIdentity(objectID: 10, uid: "shared-uid")
        let filteredOutObject = CoreAudioObjectIdentity(objectID: 20, uid: "shared-uid")
        let uniqueObject = CoreAudioObjectIdentity(objectID: 30, uid: "unique-uid")
        let confirmed = CoreAudioIdentityInventory.confirmedObjects(
            [visibleObject, filteredOutObject, uniqueObject], complete: true)
        let visibleDevice = halDevice(uid: "shared-uid")
        let uniqueDevice = halDevice(uid: "unique-uid", transport: .usb)
        let displayed = halSnapshot([visibleDevice, uniqueDevice], objects: confirmed)

        XCTAssertEqual(confirmed, ["unique-uid": 30],
                       "Filtering the second object from display must not establish raw UID uniqueness.")
        XCTAssertNil(AudioVolumeIdentity.resolve(visibleDevice, hal: displayed, routes: routeSnapshot([])))
        XCTAssertEqual(AudioVolumeIdentity.resolve(uniqueDevice, hal: displayed, routes: routeSnapshot([])),
                       AudioVolumeIdentity(uid: "unique-uid", objectID: 30, receiverID: nil))
    }

    func testIncompleteRawInventoryOrMalformedObjectIdentityConfirmsNoTargets() {
        let unique = CoreAudioObjectIdentity(objectID: 10, uid: "unique-uid")
        let cases: [(String, [CoreAudioObjectIdentity], Bool)] = [
            ("incomplete inventory", [unique], false),
            ("empty UID", [unique, CoreAudioObjectIdentity(objectID: 20, uid: "")], true),
            ("object ID reused for another UID", [unique, CoreAudioObjectIdentity(objectID: 10, uid: "other-uid")], true),
            ("same object repeated", [unique, unique], true),
        ]

        for (reason, identities, complete) in cases {
            XCTAssertTrue(CoreAudioIdentityInventory.confirmedObjects(identities, complete: complete).isEmpty, reason)
        }
    }

    func testVisibleUniqueHALRowDoesNotSubstituteForRawInventoryEvidence() {
        let speaker = halDevice(uid: "speaker")
        let hal = CoreAudioSnapshot(devices: [speaker], currentDeviceID: speaker.id,
                                    systemSoundDeviceID: speaker.id, warnings: [])

        XCTAssertTrue(hal.confirmedDeviceObjects.isEmpty, "Ordinary snapshot construction must default to no evidence.")
        XCTAssertNil(AudioVolumeIdentity.resolve(speaker, hal: hal, routes: routeSnapshot([])))
    }

    func testHALVolumeRequiresEvidenceForExactUIDAndOneVisibleTarget() {
        let speaker = halDevice(uid: "speaker")
        let emptyRoutes = routeSnapshot([])
        XCTAssertNil(AudioVolumeIdentity.resolve(speaker,
            hal: halSnapshot([speaker], objects: ["another-device": 9]), routes: emptyRoutes))
        XCTAssertNil(AudioVolumeIdentity.resolve(speaker,
            hal: halSnapshot([], objects: ["speaker": 10]), routes: emptyRoutes))
        XCTAssertNil(AudioVolumeIdentity.resolve(speaker,
            hal: halSnapshot([speaker, speaker], objects: ["speaker": 10]), routes: emptyRoutes))
        XCTAssertEqual(AudioVolumeIdentity.resolve(speaker,
            hal: halSnapshot([speaker], objects: ["speaker": 10]), routes: emptyRoutes),
            AudioVolumeIdentity(uid: "speaker", objectID: 10, receiverID: nil))
    }

    func testHALVolumeDoesNotRequireTargetToBeCurrentOutputOrSwitchable() {
        var speaker = halDevice(uid: "speaker")
        speaker.isAvailable = false
        let current = halDevice(uid: "usb", transport: .usb)
        let hal = halSnapshot([speaker, current], current: current.id, objects: ["speaker": 10, "usb": 11])

        XCTAssertEqual(AudioVolumeIdentity.resolve(speaker, hal: hal, routes: routeSnapshot([])),
                       AudioVolumeIdentity(uid: "speaker", objectID: 10, receiverID: nil))
    }

    func testUnresolvedHALAirPlayCannotBecomeVolumeTargetEvenWithRawUIDEvidence() {
        let stream = halDevice(uid: "temporary-stream", transport: .airplay)
        let hal = halSnapshot([stream], current: stream.id, objects: ["temporary-stream": 20])

        XCTAssertNil(AudioVolumeIdentity.resolve(stream, hal: hal, routes: routeSnapshot([])))
    }

    func testReceiverDirectoryUIDAndSelectedFlagDoNotReplaceStrictAssociation() {
        let stream = halDevice(uid: "stream", transport: .airplay)
        let routes = routeSnapshot([route(identifier: "receiver", uid: "stream", selected: true)])
        let hal = halSnapshot([stream], current: stream.id, objects: ["stream": 20])

        XCTAssertNil(routes.selectedVolumeAssociation, "A normal route snapshot must not infer strict evidence.")
        XCTAssertNil(AudioVolumeIdentity.resolve(receiverDevice(), hal: hal, routes: routes))
    }

    func testStrictReceiverAssociationRequiresRawUniqueHALAndActualDefaultOutput() {
        let stream = halDevice(uid: "stream", transport: .airplay)
        let speaker = halDevice(uid: "speaker")
        let routes = selectedRoutes()
        let receiver = receiverDevice()

        XCTAssertNil(AudioVolumeIdentity.resolve(receiver,
            hal: halSnapshot([stream], current: stream.id), routes: routes))
        XCTAssertNil(AudioVolumeIdentity.resolve(receiver,
            hal: halSnapshot([stream], objects: ["stream": 20]), routes: routes))
        XCTAssertNil(AudioVolumeIdentity.resolve(receiver,
            hal: halSnapshot([stream, speaker], current: speaker.id, objects: ["stream": 20, "speaker": 10]), routes: routes))
        XCTAssertNil(AudioVolumeIdentity.resolve(receiver,
            hal: halSnapshot([stream, stream], current: stream.id, objects: ["stream": 20]), routes: routes))
        XCTAssertEqual(AudioVolumeIdentity.resolve(receiver,
            hal: halSnapshot([stream], current: stream.id, objects: ["stream": 20]), routes: routes),
            AudioVolumeIdentity(uid: "stream", objectID: 20, receiverID: "receiver"))
    }

    func testReceiverAssociationRejectsConflictingOrIncompleteRouteEvidence() {
        let stream = halDevice(uid: "stream", transport: .airplay)
        let hal = halSnapshot([stream], current: stream.id, objects: ["stream": 20])
        let selected = route(identifier: "receiver", uid: "stream", selected: true)
        let cases: [(String, PrivateRouteSnapshot)] = [
            ("receiver absent", selectedRoutes([])),
            ("duplicate receiver", selectedRoutes([selected, selected])),
            ("UID shared by receivers", selectedRoutes([selected, route(identifier: "other", uid: "stream")])),
            ("not selected", selectedRoutes([route(identifier: "receiver", uid: "stream")])),
            ("directory UID absent", selectedRoutes([route(identifier: "receiver", uid: nil, selected: true)])),
            ("directory UID differs", selectedRoutes([route(identifier: "receiver", uid: "old-stream", selected: true)])),
            ("association receiver differs", selectedRoutes([selected], identifier: "other")),
            ("association UID absent", selectedRoutes([selected], uid: "")),
            ("association UID differs", selectedRoutes([selected], uid: "old-stream")),
        ]

        for (reason, routes) in cases {
            XCTAssertNil(AudioVolumeIdentity.resolve(receiverDevice(), hal: hal, routes: routes), reason)
        }
    }

    func testStrictReceiverVolumeEvidenceDoesNotGrantOrRequireSwitchingCapability() {
        let stream = halDevice(uid: "stream", transport: .airplay)
        let hal = halSnapshot([stream], current: stream.id, objects: ["stream": 20])
        let routes = selectedRoutes([route(identifier: "receiver", uid: "stream", selected: true, canSelect: false)])
        let catalog = AudioCatalog.merge(hal: hal, routes: routes)
        guard let receiver = catalog.devices.first(where: { $0.id == "route:receiver" }) else {
            return XCTFail("The catalog must retain the known receiver.")
        }

        XCTAssertFalse(receiver.isAvailable)
        XCTAssertEqual(AudioVolumeIdentity.resolve(receiver, hal: hal, routes: routes),
                       AudioVolumeIdentity(uid: "stream", objectID: 20, receiverID: "receiver"))
    }

    func testCatalogDoesNotInferShortcutIdentityForUnresolvedAirPlay() {
        let stream = halDevice(uid: "temporary-stream", transport: .airplay)
        let catalog = AudioCatalog.merge(
            hal: halSnapshot([stream], current: stream.id, objects: ["temporary-stream": 20]),
            routes: routeSnapshot([]))

        XCTAssertEqual(catalog.devices.count, 1)
        XCTAssertNil(catalog.devices.first?.shortcutTarget)
        XCTAssertFalse(catalog.devices.first?.isAvailable ?? true)
    }

    func testCatalogUsesReceiverShortcutIdentityInsteadOfTemporaryStreamUID() {
        for uid in ["first-stream", "replacement-stream"] {
            let stream = halDevice(uid: uid, transport: .airplay)
            let catalog = AudioCatalog.merge(
                hal: halSnapshot([stream], current: stream.id),
                routes: routeSnapshot([route(identifier: "receiver", uid: uid, selected: true)],
                                      confirmed: ["receiver"]))

            XCTAssertEqual(catalog.devices.map(\.id), ["route:receiver"])
            XCTAssertEqual(catalog.devices.first?.shortcutTarget, .receiver(identifier: "receiver"))
            XCTAssertNotEqual(catalog.devices.first?.shortcutTarget, .hal(uid: uid))
        }
    }

    func testCatalogKeepsDistinctReceiverIdentitiesWhenNamesMatchAndTargetsCannotSwitch() {
        let catalog = AudioCatalog.merge(hal: halSnapshot([]), routes: routeSnapshot([
            route(identifier: "receiver-one", uid: nil, canSelect: false),
            route(identifier: "receiver-two", uid: nil, canSelect: false),
        ], confirmed: ["receiver-one", "receiver-two"]))

        XCTAssertEqual(catalog.devices.count, 2)
        XCTAssertTrue(catalog.devices.allSatisfy { !$0.isAvailable })
        XCTAssertEqual(Set(catalog.devices.compactMap(\.shortcutTarget)),
                       Set([AudioTargetIdentity.receiver(identifier: "receiver-one"),
                            .receiver(identifier: "receiver-two")]))
    }

    func testCatalogCannotGrantReceiverShortcutForDuplicateReceiverIdentity() {
        let duplicate = route(identifier: "receiver", uid: nil)
        let catalog = AudioCatalog.merge(hal: halSnapshot([]), routes: routeSnapshot([duplicate, duplicate]))

        XCTAssertTrue(catalog.devices.isEmpty)
        XCTAssertNotNil(catalog.warning)
    }

    func testVisibleUniqueReceiverWithoutBindingEvidenceRemainsVisibleButCannotBind() {
        let routes = PrivateRouteSnapshot(
            routes: [route(identifier: "receiver", uid: nil)], warning: nil, diagnostics: "no binding evidence")
        let catalog = AudioCatalog.merge(hal: halSnapshot([]), routes: routes)

        XCTAssertTrue(routes.confirmedShortcutIdentifiers.isEmpty)
        XCTAssertEqual(catalog.devices.map(\.id), ["route:receiver"])
        XCTAssertNil(catalog.devices.first?.shortcutTarget,
                     "One displayed receiver is not proof that the raw source had a unique identity.")
    }

    func testCachedDuplicateEndpointRemainsBindingConflictAfterDisplayFilteringAndCatalogMerges() {
        let endpoint: [String: Any] = [
            "identifier": "receiver", "name": "Endpoint receiver", "deviceFeatures": 1,
            "isRemoteControlOnly": false, "wrapperIsCached": false,
        ]
        var cachedDuplicate = endpoint
        cachedDuplicate["wrapperIsCached"] = true
        let uniqueEndpoint = PrivateRouteSnapshotAdapter.endpointDiscovery([
            "endpoints": [endpoint], "incompleteDeviceCount": 0,
        ])
        let conflictingEndpoints = PrivateRouteSnapshotAdapter.endpointDiscovery([
            "endpoints": [endpoint, cachedDuplicate], "incompleteDeviceCount": 0,
        ])
        let selection = PrivateRouteSnapshotAdapter.systemSelection([
            "selection": NSNull(), "isUnselectedConfirmed": true,
        ])
        let retained = PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true])

        XCTAssertEqual(conflictingEndpoints.routes, uniqueEndpoint.routes,
                       "The cached duplicate must stay filtered from the ordinary display catalog.")
        XCTAssertEqual(conflictingEndpoints.routes.map(\.identifier), ["receiver"])
        XCTAssertTrue(conflictingEndpoints.bindingIdentity.confirmed.isEmpty)
        XCTAssertEqual(conflictingEndpoints.bindingIdentity.conflicted, ["receiver"])

        let avRow: [String: Any] = [
            "identifier": "receiver", "name": "AV receiver", "uid": NSNull(),
            "transport": "airplay", "canSelect": false, "isSelected": false,
        ]
        // A conflict in the raw endpoint source must also veto another source's
        // otherwise unique binding evidence; display precedence stays unchanged.
        for avRows in [[], [avRow]] {
            let av = PrivateRouteSnapshotAdapter.avDiscovery(["routes": avRows])
            let baseline = PrivateRouteCatalog.merge(av: av, endpoints: uniqueEndpoint,
                                                       selection: selection, retained: retained)
            let conflicted = PrivateRouteCatalog.merge(av: av, endpoints: conflictingEndpoints,
                                                         selection: selection, retained: retained)
            let baselineCatalog = AudioCatalog.merge(hal: halSnapshot([]), routes: baseline)
            let catalog = AudioCatalog.merge(hal: halSnapshot([]), routes: conflicted)

            XCTAssertEqual(baseline.confirmedShortcutIdentifiers, ["receiver"])
            XCTAssertEqual(baselineCatalog.devices.first?.shortcutTarget, .receiver(identifier: "receiver"))
            XCTAssertEqual(conflicted.routes, baseline.routes,
                           "Binding evidence must not silently change ordinary discovery or switching capability.")
            XCTAssertTrue(conflicted.confirmedShortcutIdentifiers.isEmpty)
            XCTAssertEqual(catalog.devices.map(\.id), ["route:receiver"])
            XCTAssertNil(catalog.devices.first?.shortcutTarget)
            XCTAssertEqual(catalog.devices.first?.isAvailable, baselineCatalog.devices.first?.isAvailable)
        }
    }

    func testRawEndpointConflictRevokesSelectedShortcutButPreservesStrictVolumeAndCurrentOutput() throws {
        let av = PrivateRouteSnapshotAdapter.avDiscovery(["routes": []])
        let emptyEndpoints = PrivateRouteSnapshotAdapter.endpointDiscovery([
            "endpoints": [], "incompleteDeviceCount": 0,
        ])
        let endpoint: [String: Any] = [
            "identifier": "receiver", "name": "Endpoint receiver", "deviceFeatures": 1,
            "isRemoteControlOnly": false, "wrapperIsCached": false,
        ]
        var cachedDuplicate = endpoint
        cachedDuplicate["wrapperIsCached"] = true
        let conflictingEndpoints = PrivateRouteSnapshotAdapter.endpointDiscovery([
            "endpoints": [endpoint, cachedDuplicate], "incompleteDeviceCount": 0,
        ])
        let selection = SystemSelectionEvidence(
            route: route(identifier: "receiver", uid: "stream", selected: true),
            diagnostics: "strict selected fixture", outcome: .succeeded)
        let retained = PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true])
        let hal = halSnapshot([halDevice(uid: "stream", transport: .airplay)],
                              current: "hal:stream", objects: ["stream": 42])
        let baseline = PrivateRouteCatalog.merge(av: av, endpoints: emptyEndpoints,
                                                  selection: selection, retained: retained)
        let conflicted = PrivateRouteCatalog.merge(av: av, endpoints: conflictingEndpoints,
                                                    selection: selection, retained: retained)
        let baselineCatalog = AudioCatalog.merge(hal: hal, routes: baseline)
        let conflictedCatalog = AudioCatalog.merge(hal: hal, routes: conflicted)
        let baselineDevice = try XCTUnwrap(baselineCatalog.devices.first)
        let conflictedDevice = try XCTUnwrap(conflictedCatalog.devices.first)
        let association = SystemRouteVolumeAssociation(identifier: "receiver", uid: "stream")
        let volumeIdentity = AudioVolumeIdentity(uid: "stream", objectID: 42, receiverID: "receiver")

        XCTAssertEqual(baseline.confirmedShortcutIdentifiers, ["receiver"])
        XCTAssertEqual(baselineDevice.shortcutTarget, .receiver(identifier: "receiver"))
        XCTAssertEqual(baseline.selectedVolumeAssociation, association)
        XCTAssertEqual(baselineCatalog.currentDeviceID, "route:receiver")
        XCTAssertEqual(AudioVolumeIdentity.resolve(baselineDevice, hal: hal, routes: baseline), volumeIdentity)

        XCTAssertEqual(conflictingEndpoints.routes.map(\.identifier), ["receiver"])
        XCTAssertEqual(conflictingEndpoints.bindingIdentity.conflicted, ["receiver"])
        XCTAssertTrue(conflicted.confirmedShortcutIdentifiers.isEmpty,
                      "Strict selection must not override a raw discovery identity conflict for persistent binding.")
        XCTAssertNil(conflictedDevice.shortcutTarget)
        XCTAssertEqual(conflicted.routes, baseline.routes)
        XCTAssertEqual(conflictedCatalog.devices.map(\.id), ["route:receiver"])
        XCTAssertEqual(conflicted.selectedVolumeAssociation, association)
        XCTAssertEqual(conflictedCatalog.currentDeviceID, "route:receiver")
        XCTAssertEqual(AudioVolumeIdentity.resolve(conflictedDevice, hal: hal, routes: conflicted), volumeIdentity,
                       "The independent strict stream association still identifies the current volume target.")
    }

    func testVerifiedRemoteCompanionPreservesBindingWithoutChangingAudioProjection() throws {
        let activePair = remoteCompanionEndpointRows()
        var idlePair = activePair
        idlePair[0]["routingContextUUID"] = NSNull()
        idlePair[0]["streamUIDs"] = [String]()
        idlePair[0]["propertyStatus"] = [
            "routingContextUUID": ["state": "null", "status": 0],
            "streams": ["state": "value", "status": 0],
        ]
        let pairWithoutDiagnostics = activePair.map { row in
            var value = row
            value.removeValue(forKey: "referenceGroup")
            return value
        }
        for rows in [activePair, Array(activePair.reversed()), idlePair, pairWithoutDiagnostics] {
            let endpoints = endpointEvidence(rows)
            let audioRow = try XCTUnwrap(rows.first { ($0["isRemoteControlOnly"] as? Bool) == false })
            let audioOnly = endpointEvidence([audioRow])
            XCTAssertEqual(endpoints.bindingIdentity.confirmed, ["receiver"])
            XCTAssertTrue(endpoints.bindingIdentity.conflicted.isEmpty)
            XCTAssertEqual(endpoints.routes, audioOnly.routes,
                           "Recognizing the remote-control companion must not add a displayed or switchable route.")
            XCTAssertFalse(try XCTUnwrap(endpoints.routes.first).canSelect)
            try assertSelectedProjection(endpoints: endpoints, hasShortcut: true)
        }

        let idleSnapshot = PrivateRouteCatalog.merge(
            av: PrivateRouteSnapshotAdapter.avDiscovery(["routes": []]), endpoints: endpointEvidence(idlePair),
            selection: PrivateRouteSnapshotAdapter.systemSelection([
                "selection": NSNull(), "isUnselectedConfirmed": true,
            ]),
            retained: PrivateRouteSnapshotAdapter.retainedSystemRoute(["sessionReadSucceeded": true]))
        let idleHAL = halSnapshot([])
        let idleCatalog = AudioCatalog.merge(hal: idleHAL, routes: idleSnapshot)
        let idleDevice = try XCTUnwrap(idleCatalog.devices.first)

        XCTAssertEqual(idleSnapshot.confirmedShortcutIdentifiers, ["receiver"])
        XCTAssertEqual(idleCatalog.devices.map(\.id), ["route:receiver"])
        XCTAssertEqual(idleDevice.shortcutTarget, .receiver(identifier: "receiver"),
                       "A verified receiver binding must survive without a current stream or retained switching capability.")
        XCTAssertFalse(idleDevice.isAvailable)
        XCTAssertFalse(try XCTUnwrap(idleSnapshot.routes.first).isSelected)
        XCTAssertNil(idleCatalog.currentDeviceID)
        XCTAssertNil(idleSnapshot.selectedVolumeAssociation)
        XCTAssertNil(AudioVolumeIdentity.resolve(idleDevice, hal: idleHAL, routes: idleSnapshot))
    }

    func testRemoteCompanionExemptionRejectsAmbiguousRolesAndAdditionalRawRows() throws {
        let pair = remoteCompanionEndpointRows()
        var secondAudio = pair[1]
        secondAudio["isRemoteControlOnly"] = false
        var anonymous = pair[1]
        anonymous.removeValue(forKey: "identifier")
        var cases: [(String, [[String: Any]])] = [
            ("two audio endpoints", [pair[0], secondAudio]),
            ("third duplicate endpoint", pair + [pair[1]]),
            ("anonymous raw row", pair + [anonymous]),
        ]
        for index in pair.indices {
            for role: Any in [NSNull(), "true", NSNumber(value: 1)] {
                var rows = pair
                rows[index]["isRemoteControlOnly"] = role
                cases.append(("unproven role at row \(index): \(role)", rows))
            }
        }
        for (reason, rows) in cases {
            let endpoints = endpointEvidence(rows)
            XCTAssertEqual(endpoints.bindingIdentity.conflicted, ["receiver"], reason)
            XCTAssertTrue(endpoints.bindingIdentity.confirmed.isEmpty, reason)
            try assertSelectedProjection(endpoints: endpoints, hasShortcut: false)
        }
    }

    func testRemoteCompanionExemptionRejectsLocalOrUnprovenLocalIdentityForBothRows() throws {
        let pair = remoteCompanionEndpointRows()
        for index in pair.indices {
            for local: Any? in [true, NSNull(), nil, NSNumber(value: 1)] {
                var rows = pair
                rows[index]["isLocalDevice"] = local
                let endpoints = endpointEvidence(rows)

                XCTAssertEqual(endpoints.bindingIdentity.conflicted, ["receiver"],
                               "Row \(index) must explicitly identify a non-local endpoint: \(String(describing: local))")
                XCTAssertTrue(endpoints.bindingIdentity.confirmed.isEmpty)
                try assertSelectedProjection(endpoints: endpoints, hasShortcut: false)
            }
        }
    }

    func testRemoteCompanionExemptionRejectsCachedAndUnprovenNativeShape() throws {
        let pair = remoteCompanionEndpointRows()
        var cases: [(String, [[String: Any]])] = []
        for index in pair.indices {
            for (key, value): (String, Any) in [
                ("wrapperIsCached", true), ("wrapperIsCached", NSNull()),
                ("isCached", true), ("isCached", NSNumber(value: 0)),
                ("type", "EndpointType_Other"),
            ] {
                var rows = pair
                rows[index][key] = value
                cases.append(("\(key) at row \(index): \(value)", rows))
            }
        }
        for (key, value): (String, Any) in [
            ("routingContextUUID", "unexpected-context"), ("streamUIDs", ["unexpected-stream"]),
            ("streamUIDs", NSNull()), ("streamUIDs", [NSNumber(value: 0)]),
        ] {
            var rows = pair
            rows[1][key] = value
            cases.append(("companion \(key): \(value)", rows))
        }
        for field in ["routingContextUUID", "streamUIDs", "propertyStatus"] {
            var rows = pair
            rows[1].removeValue(forKey: field)
            cases.append(("missing companion \(field)", rows))
        }
        for field in ["routingContextUUID", "streams"] {
            for status: [String: Any] in [
                ["state": "readFailed", "status": -12784],
                ["state": field == "streams" ? "value" : "null", "status": false],
                ["state": field == "streams" ? "value" : "null", "status": "0"],
            ] {
                var rows = pair
                var statuses = try XCTUnwrap(rows[1]["propertyStatus"] as? [String: Any])
                statuses[field] = status
                rows[1]["propertyStatus"] = statuses
                cases.append(("unproven companion getter \(field): \(status)", rows))
            }
        }
        for records: Any? in [nil, NSNull(), [["identifier": ["state": "readFailed", "status": -12784]]]] {
            var rows = pair
            var statuses = try XCTUnwrap(rows[1]["propertyStatus"] as? [String: Any])
            statuses["streamIdentifiers"] = records
            rows[1]["propertyStatus"] = statuses
            cases.append(("unproven empty companion stream array: \(String(describing: records))", rows))
        }
        for (reason, rows) in cases {
            let endpoints = endpointEvidence(rows)
            XCTAssertEqual(endpoints.bindingIdentity.conflicted, ["receiver"], reason)
            XCTAssertTrue(endpoints.bindingIdentity.confirmed.isEmpty, reason)
            try assertSelectedProjection(endpoints: endpoints, hasShortcut: false)
        }
    }

    func testRemoteCompanionExemptionRequiresStableThreeWayIdentityForBothRows() throws {
        let pair = remoteCompanionEndpointRows()
        for index in pair.indices {
            for (field, value): (String, Any) in [
                ("endpointIdentifier", "another-endpoint"), ("avDeviceIdentifier", "another-device"),
                ("readbackStable", false), ("readbackStable", NSNull()), ("readbackStable", NSNumber(value: 1)),
            ] {
                var rows = pair
                var identity = try XCTUnwrap(rows[index]["avIdentity"] as? [String: Any])
                identity[field] = value
                rows[index]["avIdentity"] = identity
                let endpoints = endpointEvidence(rows)
                XCTAssertEqual(endpoints.bindingIdentity.conflicted, ["receiver"], "row \(index): \(field)")
                XCTAssertTrue(endpoints.bindingIdentity.confirmed.isEmpty)
                try assertSelectedProjection(endpoints: endpoints, hasShortcut: false)
            }
            var rows = pair
            rows[index]["avIdentity"] = ["endpointIdentifier": "another-receiver",
                                        "avDeviceIdentifier": "another-receiver", "readbackStable": true]
            let endpoints = endpointEvidence(rows)
            XCTAssertEqual(endpoints.bindingIdentity.conflicted, ["receiver"],
                           "Matching endpoint and AV identifiers must still agree with the raw row identifier.")
            try assertSelectedProjection(endpoints: endpoints, hasShortcut: false)
        }
    }

    func testRemoteCompanionConfirmationCannotOverrideConflictFromAVDiscovery() throws {
        let endpoints = endpointEvidence(remoteCompanionEndpointRows())
        let avRow: [String: Any] = [
            "identifier": "receiver", "name": "Receiver", "uid": NSNull(),
            "transport": "airplay", "canSelect": false, "isSelected": false,
            "selectionEvidence": ["identityUnique": true],
        ]
        let av = PrivateRouteSnapshotAdapter.avDiscovery(["routes": [avRow, avRow]])

        XCTAssertEqual(endpoints.bindingIdentity.confirmed, ["receiver"])
        XCTAssertTrue(endpoints.bindingIdentity.conflicted.isEmpty)
        XCTAssertEqual(av.bindingIdentity.conflicted, ["receiver"])
        try assertSelectedProjection(endpoints: endpoints, av: av, hasShortcut: false)
    }

    // Shape observed in native-r01/live-r12.jsonl, with fixture identities.
    // The audio endpoint's stream ID is intentionally distinct from the strict HAL stream.
    private func remoteCompanionEndpointRows() -> [[String: Any]] {
        let audio: [String: Any] = [
            "referenceGroup": 0, "identifier": "receiver", "name": "Receiver", "type": "EndpointType_AirPlay",
            "deviceFeatures": 1, "isLocalDevice": false, "isRemoteControlOnly": false,
            "wrapperIsCached": false, "isCached": NSNull(), "isDeviceDisabled": false, "requiresAuthorization": false,
            "deviceEligibility": ["supportsAudio": true, "isCached": false,
                                  "isDeviceDisabled": false, "requiresAuthorization": false],
            "routingContextUUID": "context", "streamUIDs": ["receiver-airplay-stream"],
            "propertyStatus": ["routingContextUUID": ["state": "value", "status": 0],
                               "streams": ["state": "value", "status": 0]],
            "avIdentity": ["endpointIdentifier": "receiver", "avDeviceIdentifier": "receiver", "readbackStable": true],
        ]
        var companion = audio
        companion["referenceGroup"] = 1
        companion["isRemoteControlOnly"] = true
        companion["routingContextUUID"] = NSNull()
        companion["streamUIDs"] = [String]()
        companion["propertyStatus"] = [
            "routingContextUUID": ["state": "null", "status": 0],
            "streams": ["state": "value", "status": 0],
            "streamIdentifiers": [Any](),
        ]
        return [audio, companion]
    }

    private func endpointEvidence(_ rows: [[String: Any]]) -> EndpointDiscoveryEvidence {
        PrivateRouteSnapshotAdapter.endpointDiscovery(["endpoints": rows, "incompleteDeviceCount": 0])
    }

    private func assertSelectedProjection(endpoints: EndpointDiscoveryEvidence, av: AVRouteDiscoveryEvidence? = nil,
                                          hasShortcut: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let selected = route(identifier: "receiver", uid: "stream", selected: true)
        let selection = SystemSelectionEvidence(route: selected, diagnostics: "strict selected fixture", outcome: .succeeded)
        let retained = PrivateRouteSnapshotAdapter.retainedSystemRoute([
            "sessionReadSucceeded": true,
            "retained": ["identifier": "receiver", "canSelect": true, "state": "selected",
                         "isSelected": true, "associatedUID": "stream", "associationReadbackStable": true],
        ])
        let emptyAV = PrivateRouteSnapshotAdapter.avDiscovery(["routes": []])
        let baseline = PrivateRouteCatalog.merge(av: emptyAV, endpoints: endpointEvidence([]),
                                                 selection: selection, retained: retained)
        let snapshot = PrivateRouteCatalog.merge(
            av: av ?? emptyAV, endpoints: endpoints, selection: selection, retained: retained)
        let hal = halSnapshot([halDevice(uid: "stream", transport: .airplay)],
                              current: "hal:stream", objects: ["stream": 42])
        let catalog = AudioCatalog.merge(hal: hal, routes: snapshot)
        let device = try XCTUnwrap(catalog.devices.first, file: file, line: line)

        XCTAssertEqual(AudioDiscoveryInventory.merge(hal: hal, routes: snapshot)
            .presence(of: .receiver(identifier: "receiver")), .found, file: file, line: line)
        XCTAssertEqual(snapshot.confirmedShortcutIdentifiers, hasShortcut ? ["receiver"] : [], file: file, line: line)
        XCTAssertEqual(device.shortcutTarget, hasShortcut ? .receiver(identifier: "receiver") : nil, file: file, line: line)
        XCTAssertEqual(snapshot.routes, baseline.routes, file: file, line: line)
        XCTAssertEqual(catalog.devices.map(\.id), ["route:receiver"], file: file, line: line)
        XCTAssertTrue(device.isAvailable, file: file, line: line)
        XCTAssertEqual(catalog.currentDeviceID, "route:receiver", file: file, line: line)
        XCTAssertEqual(snapshot.selectedVolumeAssociation, SystemRouteVolumeAssociation(identifier: "receiver", uid: "stream"),
                       file: file, line: line)
        XCTAssertEqual(AudioVolumeIdentity.resolve(device, hal: hal, routes: snapshot),
                       AudioVolumeIdentity(uid: "stream", objectID: 42, receiverID: "receiver"), file: file, line: line)
    }

    private func currentLayoutLetterKey(where matches: (String) -> Bool) throws -> (code: UInt16, letter: String) {
        for code in DeviceShortcut.supportedKeyCodes.sorted() {
            let letter = ShortcutKeyDisplay.keyName(code)
            if letter.count == 1, "ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(letter), matches(letter) {
                return (code, letter)
            }
        }
        throw XCTSkip("The current keyboard layout has no matching letter key for this menu regression.")
    }

    private func halDevice(uid: String, transport: AudioTransport = .speaker) -> AudioDevice {
        AudioDevice(id: "hal:\(uid)", name: "Output", transport: transport, backend: .coreAudio(uid: uid))
    }

    private func receiverDevice() -> AudioDevice {
        AudioDevice(id: "route:receiver", name: "Receiver", transport: .airplay,
                    backend: .privateRoute(identifier: "receiver"))
    }

    private func halSnapshot(_ devices: [AudioDevice], current: String? = nil,
                             objects: [String: UInt32] = [:]) -> CoreAudioSnapshot {
        CoreAudioSnapshot(devices: devices, currentDeviceID: current, systemSoundDeviceID: current,
                          warnings: [], confirmedDeviceObjects: objects)
    }

    private func route(identifier: String, uid: String?, selected: Bool = false,
                       canSelect: Bool = true) -> PrivateAudioRoute {
        PrivateAudioRoute(identifier: identifier, name: "Same receiver name", uid: uid,
                          isSelected: selected, canSelect: canSelect, transport: "airplay")
    }

    private func routeSnapshot(_ routes: [PrivateAudioRoute], confirmed: Set<String> = []) -> PrivateRouteSnapshot {
        PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "boundary fixture",
                             confirmedShortcutIdentifiers: confirmed,
                             discovery: .init(observedIdentifiers: Set(routes.map(\.identifier)), isComplete: true))
    }

    private func selectedRoutes(_ routes: [PrivateAudioRoute]? = nil, identifier: String = "receiver",
                                uid: String = "stream") -> PrivateRouteSnapshot {
        PrivateRouteSnapshot(routes: routes ?? [route(identifier: "receiver", uid: "stream", selected: true)],
                             warning: nil, diagnostics: "strict association fixture",
                             selectedVolumeAssociation: SystemRouteVolumeAssociation(identifier: identifier, uid: uid))
    }
}

private final class InteractionSubmissionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ value: String) { lock.withLock { events.append(value) } }
    func values() -> [String] { lock.withLock { events } }
}
