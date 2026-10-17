import XCTest
@testable import ToneHop

@MainActor
final class ShortcutStoreTests: XCTestCase {
    private let target = AudioTargetIdentity.hal(uid: "complete-uid-a")
    private func key(_ code: UInt16 = 40) throws -> DeviceShortcut {
        try DeviceShortcut(keyCode: code, modifiers: .command)
    }
    private func binding() throws -> ShortcutBinding {
        ShortcutBinding(target: target, shortcut: try key(), lastKnownName: "Speakers")
    }
    private func device(_ target: AudioTargetIdentity, name: String = "Renamed Speakers") -> AudioDevice {
        AudioDevice(id: "display-id", name: name, transport: .speaker,
                    backend: .coreAudio(uid: "backend-is-not-the-binding-authority"), shortcutTarget: target)
    }

    func testSavedAndNewlyDiscoveredNamesArePreservedAcrossAppLanguages() async throws {
        let savedName = "Bedroom 卧室 🎵 %@"
        let discoveredName = "取消 Café Speakers"
        let saved = ShortcutBinding(target: target, shortcut: try key(), lastKnownName: savedName)
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Name updates must not select output") },
                                  preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        XCTAssertEqual(store.confirmingBindings.first?.lastKnownName, savedName)
        XCTAssertEqual(prefs.saveAttempts, 0)

        store.updateDevices([device(target, name: discoveredName)])
        await store.drain()
        XCTAssertEqual(store.bindings.first?.lastKnownName, discoveredName)
        XCTAssertEqual(prefs.bindings.first?.lastKnownName, discoveredName)
        XCTAssertEqual(store.bindings.first?.target, saved.target)
        XCTAssertEqual(store.bindings.first?.shortcut, saved.shortcut)
        XCTAssertEqual(store.bindings.first?.revision, saved.revision)
        store.updateDevices([], discovery: .init(hal: .init(isComplete: true)))
        await store.drain()
        let request = store.requestRecordRemoval(bindingID: saved.id)
        XCTAssertEqual(request?.deviceName, discoveredName)
        store.stop()
    }

    func testInitIsInertAndStartRegistersOfflineBinding() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        var selections = 0
        let store = ShortcutStore(selectTarget: { _, _ in selections += 1 }, preferences: prefs, registrar: registrar)
        XCTAssertEqual(prefs.loads, 0)
        XCTAssertTrue(registrar.registered.isEmpty)
        store.start()
        await store.drain()
        store.start()
        await store.drain()
        XCTAssertEqual(prefs.loads, 1)
        XCTAssertTrue(store.offlineBindings.isEmpty)
        XCTAssertEqual(store.confirmingBindings, [saved])
        XCTAssertEqual(registrar.registered.count, 1)
        store.updateDevices([device(target)])
        await store.drain()
        XCTAssertTrue(store.offlineBindings.isEmpty)
        store.updateDevices([], discovery: .init(hal: .init(isComplete: true)))
        await store.drain()
        XCTAssertEqual(store.offlineBindings, store.bindings)
        XCTAssertTrue(store.confirmingBindings.isEmpty)
        XCTAssertEqual(registrar.registered.count, 1)
        XCTAssertEqual(prefs.saves, 1) // Name metadata only; identity/revision stay fixed.
        XCTAssertEqual(store.bindings.first?.lastKnownName, "Renamed Speakers")
        XCTAssertEqual(store.bindings.first?.revision, saved.revision)
        XCTAssertEqual(selections, 0)
    }

    func testMissingIdentityDoesNotGrantNewBindingFromBackend() async throws {
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("No audio action") },
                                  preferences: ShortcutTestPreferences(), registrar: ShortcutTestRegistrar())
        store.start()
        await store.drain()
        store.updateDevices([AudioDevice(id: "hal:complete-uid-a", name: "Speakers", transport: .speaker,
                                         backend: .coreAudio(uid: "complete-uid-a"))])
        await store.drain()
        XCTAssertFalse(store.beginRecording(target: target, deviceName: "Speakers"))
    }

    func testUnconfirmedSavedTargetCannotBeEditedOrRemovedAndDoesNotDuplicateVisibleRow() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Discovery cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        XCTAssertEqual(store.confirmingBindings, [saved])
        XCTAssertTrue(store.offlineBindings.isEmpty)
        XCTAssertFalse(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertNil(store.requestRecordRemoval(bindingID: saved.id))
        store.updateDevices([AudioDevice(id: "hal:complete-uid-a", name: "Speakers", transport: .speaker,
                                          backend: .coreAudio(uid: "complete-uid-a"), isAvailable: false)],
                            discovery: .init(hal: .init(observedIdentifiers: ["complete-uid-a"])))
        XCTAssertTrue(store.confirmingBindings.isEmpty, "The identity-confirming row is already displayed.")
        XCTAssertTrue(store.offlineBindings.isEmpty)
        XCTAssertFalse(store.canRecord(target: target))
        XCTAssertFalse(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertNil(store.requestRecordRemoval(bindingID: saved.id))
        XCTAssertEqual(prefs.saveAttempts, 0)
    }

    func testFoundDeviceWithoutSwitchCapabilityMayRecordButCannotRemoveRecord() async throws {
        let receiver = AudioTargetIdentity.receiver(identifier: "receiver-a")
        let saved = ShortcutBinding(target: receiver, shortcut: try key(), lastKnownName: "Bedroom")
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Recording cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([AudioDevice(id: "route:receiver-a", name: "Bedroom", transport: .airplay,
                                          backend: .privateRoute(identifier: "receiver-a"), isAvailable: false,
                                          unavailableReason: "Missing switching references", shortcutTarget: receiver)],
                            discovery: .init(receivers: .init(observedIdentifiers: ["receiver-a"], isComplete: true)))
        store.start()
        await store.drain()
        XCTAssertTrue(store.offlineBindings.isEmpty)
        XCTAssertTrue(store.confirmingBindings.isEmpty)
        XCTAssertNil(store.requestRecordRemoval(bindingID: saved.id))
        XCTAssertTrue(store.canRecord(target: receiver))
        XCTAssertTrue(store.beginRecording(target: receiver, deviceName: "Bedroom"))
        store.cancelRecording()
        XCTAssertEqual(prefs.saveAttempts, 0)
    }

    func testObservedReceiverWithConflictedBindingIdentityIsFoundAndCannotRemoveRecord() async throws {
        let receiver = AudioTargetIdentity.receiver(identifier: "receiver-a")
        let saved = ShortcutBinding(target: receiver, shortcut: try key(), lastKnownName: "Bedroom")
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let discovery = AudioDiscoveryInventory(receivers: .init(observedIdentifiers: ["receiver-a"],
                                                                 conflictedIdentifiers: ["receiver-a"],
                                                                 isComplete: true))
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Discovery cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([AudioDevice(id: "route:receiver-a", name: "Bedroom", transport: .airplay,
                                          backend: .privateRoute(identifier: "receiver-a"), shortcutTarget: nil)],
                            discovery: discovery)
        store.start()
        await store.drain()
        XCTAssertEqual(discovery.presence(of: receiver), .found)
        XCTAssertTrue(store.offlineBindings.isEmpty)
        XCTAssertTrue(store.confirmingBindings.isEmpty, "The discovered row already represents the saved target.")
        XCTAssertFalse(store.canRecord(target: receiver))
        XCTAssertNil(store.requestRecordRemoval(bindingID: saved.id))
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.saveAttempts, 0)
    }

    func testRecordRemovalRechecksDiscoveryBeforeConfirmation() async throws {
        for recoveredEvidence in [AudioDiscoveryInventory.unconfirmed,
                                  .init(hal: .init(observedIdentifiers: ["complete-uid-a"], isComplete: true))] {
            let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
            prefs.bindings = [saved]
            let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Removal cannot select") },
                                      preferences: prefs, registrar: registrar)
            store.updateDevices([], discovery: .init(hal: .init(isComplete: true)))
            store.start()
            await store.drain()
            XCTAssertEqual(store.offlineBindings, [saved])
            XCTAssertFalse(store.beginRecording(target: target, deviceName: "Speakers"))
            let request = try XCTUnwrap(store.requestRecordRemoval(bindingID: saved.id))
            store.updateDevices([], discovery: recoveredEvidence)
            XCTAssertFalse(store.confirmDeletion(request))
            XCTAssertFalse(store.confirmDeletion(request))
            XCTAssertTrue(store.canEdit)
            XCTAssertTrue(registrar.deliveryEnabled)
            XCTAssertEqual(prefs.saveAttempts, 0)
            XCTAssertEqual(store.bindings, [saved])
        }
    }

    func testBackspaceClearsActiveBindingAndRestoresOtherRegistrationsWithoutConfirmation() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let other = ShortcutBinding(target: .hal(uid: "other"), shortcut: try key(38), lastKnownName: "Other")
        prefs.bindings = [saved, other]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Clearing cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        XCTAssertFalse(store.clearRecording(), "Backspace outside recording has no action.")
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(registrar.registered.isEmpty)
        XCTAssertTrue(store.clearRecording())
        XCTAssertFalse(store.isRecording)
        XCTAssertFalse(store.clearRecording(), "The accepted action cannot repeat.")
        await store.drain()
        XCTAssertEqual(store.bindings, [other])
        XCTAssertEqual(prefs.bindings, [other])
        XCTAssertEqual(prefs.saveAttempts, 1)
        XCTAssertEqual(Set(registrar.registered.values), [other.shortcut])
        XCTAssertNil(store.registrationStates[saved.id])
        XCTAssertTrue(registrar.deliveryEnabled)
    }

    func testBackspaceInEmptyRecorderEndsWithoutWritingPreferences() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Clearing cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(store.clearRecording())
        await store.drain()
        XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.bindings.isEmpty)
        XCTAssertEqual(prefs.saveAttempts, 0)
        XCTAssertTrue(registrar.deliveryEnabled)
    }

    func testBackspaceSaveFailurePreservesBindingAndRestoresRegistration() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Clearing cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        prefs.failSave = true
        XCTAssertTrue(store.clearRecording())
        await store.drain()
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.bindings, [saved])
        XCTAssertEqual(Set(registrar.registered.values), [saved.shortcut])
        XCTAssertEqual(store.registrationStates[saved.id], .registered)
        XCTAssertTrue(registrar.deliveryEnabled)
        XCTAssertTrue(store.message?.contains(expectedLocalized("The shortcut was not cleared", "未清除快捷键")) == true)
    }

    func testLosingIdentityCancelsExistingRecordingWithoutClearingBinding() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Discovery cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        store.updateDevices([])
        XCTAssertFalse(store.isRecording)
        XCTAssertFalse(store.clearRecording())
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(Set(registrar.registered.values), [saved.shortcut])
        XCTAssertEqual(prefs.saveAttempts, 0)
    }

    func testRecordingUnregistersAndCancellationRestoresWithoutSaving() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        var selections = 0
        let store = ShortcutStore(selectTarget: { _, _ in selections += 1 }, preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        let oldToken = try XCTUnwrap(registrar.registered.keys.first)
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(registrar.registered.isEmpty)
        registrar.onPress?(oldToken)
        XCTAssertEqual(selections, 0)
        store.cancelRecording()
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(registrar.registered.count, 1)
        XCTAssertEqual(prefs.saves, 0)
    }

    func testDuplicateOfflineCombinationAndSystemReadFailureKeepDraftAndOldData() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let saved = try binding()
        prefs.bindings = [saved]
        let second = AudioTargetIdentity.receiver(identifier: "receiver-b")
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        store.updateDevices([device(second)])
        await store.drain()
        XCTAssertTrue(store.beginRecording(target: second, deviceName: "Receiver"))
        XCTAssertFalse(store.commitRecording(try key()))
        await store.drain()
        XCTAssertTrue(store.isRecording)
        XCTAssertEqual(prefs.bindings, [saved])
        registrar.failSystemQuery = true
        XCTAssertFalse(store.commitRecording(try key(38)))
        await store.drain()
        XCTAssertTrue(store.isRecording)
        XCTAssertEqual(prefs.saves, 0)
        registrar.failSystemQuery = false
        store.cancelRecording()
    }

    func testConflictBelongsToRecordingRowKeepsDraftAndCancellationHandlesOnlyValidation() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let second = AudioTargetIdentity.receiver(identifier: "receiver-b")
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Recording must not select output") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers"), device(second, name: "Receiver")])
        store.start()
        await store.drain()
        XCTAssertTrue(store.beginRecording(target: second, deviceName: "Receiver"))
        XCTAssertFalse(store.commitRecording(saved.shortcut))
        let firstEvent = try XCTUnwrap(store.failureEvent)
        XCTAssertFalse(store.commitRecording(saved.shortcut))
        let repeatedEvent = try XCTUnwrap(store.failureEvent)
        XCTAssertNotEqual(firstEvent.id, repeatedEvent.id)
        XCTAssertEqual(firstEvent.message, repeatedEvent.message)
        let label = ShortcutKeyDisplay.label(saved.shortcut)
        XCTAssertEqual(store.rowDraftLabel(for: second), label)
        XCTAssertEqual(store.rowIssue(for: second), expectedLocalized("\(label) is assigned to Speakers", "\(label) 已用于 Speakers"))
        XCTAssertNil(store.rowIssue(for: target), "The row owning the existing key is not the failed recording target.")
        XCTAssertNil(store.footerMessage, "The conflict is already explained beside its target.")
        store.updateDevices([device(target, name: "Speakers"), device(second, name: "Receiver")])
        XCTAssertEqual(store.failureEvent, repeatedEvent)
        XCTAssertEqual(store.rowDraftLabel(for: second), label)
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.saves, 0)
        store.cancelRecording()
        XCTAssertEqual(store.failureEvent, repeatedEvent, "Cancelling a draft does not emit another failure.")
        XCTAssertNil(store.rowIssue(for: second))
        XCTAssertNil(store.rowDraftLabel(for: second))
        XCTAssertEqual(Set(registrar.registered.values), [saved.shortcut])
        store.stop()
    }

    func testSaveFailureStaysOnItsTargetThroughFocusCancellationAndUnrelatedEditing() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let other = AudioTargetIdentity.receiver(identifier: "receiver-b")
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Editing must not select output") },
                                  preferences: prefs, registrar: registrar)
        let visible = [device(target, name: "Speakers"), device(other, name: "Receiver")]
        store.updateDevices(visible)
        store.start()
        await store.drain()
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        prefs.failSave = true
        XCTAssertTrue(store.commitRecording(try key(38)))
        await store.drain()
        let issue = try XCTUnwrap(store.rowIssue(for: target))
        let saveFailureEvent = try XCTUnwrap(store.failureEvent)
        XCTAssertTrue(issue.contains(expectedLocalized("The new shortcut was not saved", "未保存新快捷键")))
        XCTAssertNil(store.rowDraftLabel(for: target), "A failed saved draft does not replace the original displayed binding.")
        XCTAssertNil(store.footerMessage)
        store.cancelRecording()
        store.updateDevices(visible)
        await store.drain()
        XCTAssertEqual(store.rowIssue(for: target), issue)
        XCTAssertEqual(store.failureEvent, saveFailureEvent)
        store.updateDevices([device(other, name: "Receiver")])
        await store.drain()
        XCTAssertEqual(store.footerMessage, issue, "A confirming placeholder does not render the shortcut error itself.")
        store.updateDevices(visible)
        await store.drain()
        XCTAssertNil(store.footerMessage, "The explanation returns to its exact shortcut row without a footer duplicate.")
        XCTAssertEqual(store.failureEvent, saveFailureEvent, "A saved error is not replayed after temporary identity loss.")
        XCTAssertTrue(store.beginRecording(target: other, deviceName: "Receiver"))
        store.cancelRecording()
        XCTAssertEqual(store.rowIssue(for: target), issue)
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(Set(registrar.registered.values), [saved.shortcut])
        prefs.failSave = false
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertNil(store.rowIssue(for: target), "Explicitly editing the failed target handles its previous failure.")
        XCTAssertTrue(store.commitRecording(try key(38)))
        await store.drain()
        XCTAssertNil(store.rowIssue(for: target))
        XCTAssertNil(store.footerMessage, "Successful edits do not publish a success notification.")
        XCTAssertEqual(store.failureEvent, saveFailureEvent, "Success keeps the last event identity unchanged.")
        store.stop()
    }

    func testSaveFailureRollsBackCandidateAndRestoresOldCombination() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Editing cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        prefs.failSave = true
        XCTAssertTrue(store.commitRecording(try key(38)))
        await store.drain()
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.bindings, [saved])
        XCTAssertEqual(Set(registrar.registered.values), [saved.shortcut])
        XCTAssertEqual(store.registrationStates[saved.id], .registered)
    }

    func testOldCombinationReleaseFailurePreventsReplacementAndCanRetry() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        registrar.failUnregister = true
        XCTAssertFalse(store.commitRecording(try key(38)))
        await store.drain()
        XCTAssertEqual(prefs.bindings, [saved])
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertFalse(registrar.orphans.isEmpty)
        guard case .failed = store.registrationStates[saved.id] else { return XCTFail("Must expose failed restoration") }
        registrar.failUnregister = false
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(registrar.orphans.isEmpty)
        XCTAssertTrue(store.commitRecording(try key(38)))
        await store.drain()
        XCTAssertEqual(store.bindings.first?.shortcut, try key(38))
        XCTAssertEqual(Set(registrar.registered.values), [try key(38)])
    }

    func testDeleteFailurePreservesBindingAndRepeatedFailureCannotDiscardOrphan() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        var selections = 0
        let store = ShortcutStore(selectTarget: { _, _ in selections += 1 }, preferences: prefs, registrar: registrar)
        store.updateDevices([], discovery: .init(hal: .init(isComplete: true)))
        store.start()
        await store.drain()
        let token = try XCTUnwrap(registrar.registered.keys.first)
        registrar.failUnregister = true
        let first = try XCTUnwrap(store.requestRecordRemoval(bindingID: saved.id))
        XCTAssertFalse(store.confirmDeletion(first))
        await store.drain()
        registrar.onPress?(token)
        XCTAssertEqual(selections, 0)
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.bindings, [saved])
        let retry = try XCTUnwrap(store.requestRecordRemoval(bindingID: saved.id))
        XCTAssertFalse(store.confirmDeletion(retry))
        await store.drain()
        XCTAssertEqual(prefs.saves, 0)
        registrar.failUnregister = false
        let recovered = try XCTUnwrap(store.requestRecordRemoval(bindingID: saved.id))
        XCTAssertTrue(store.confirmDeletion(recovered))
        await store.drain()
        XCTAssertTrue(prefs.bindings.isEmpty)
        XCTAssertTrue(registrar.orphans.isEmpty)
        XCTAssertEqual(selections, 0)
    }

    func testDeleteSaveFailureRestoresOriginalBindingAndRegistration() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.updateDevices([], discovery: .init(hal: .init(isComplete: true)))
        store.start()
        await store.drain()
        let request = try XCTUnwrap(store.requestRecordRemoval(bindingID: saved.id))
        prefs.failSave = true
        XCTAssertTrue(store.confirmDeletion(request))
        await store.drain()
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(Set(registrar.registered.values), [saved.shortcut])
        XCTAssertTrue(registrar.deliveryEnabled)
    }

    func testDeletionCancelAndExitInvalidationCannotDeleteNewRevisionOrLeaveGateClosed() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.updateDevices([], discovery: .init(hal: .init(isComplete: true)))
        store.start()
        await store.drain()
        let cancelled = try XCTUnwrap(store.requestRecordRemoval(bindingID: saved.id))
        store.cancelDeletion(cancelled)
        XCTAssertFalse(store.confirmDeletion(cancelled))
        await store.drain()
        XCTAssertEqual(prefs.saves, 0)
        let interrupted = try XCTUnwrap(store.requestRecordRemoval(bindingID: saved.id))
        store.setSuspended(.quitting, true)
        XCTAssertFalse(store.confirmDeletion(interrupted))
        await store.drain()
        store.setSuspended(.quitting, false)
        XCTAssertTrue(registrar.deliveryEnabled)
        store.updateDevices([device(target, name: "Speakers")])
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(store.commitRecording(try key(38)))
        await store.drain()
        XCTAssertFalse(store.confirmDeletion(interrupted))
        await store.drain()
        XCTAssertEqual(store.bindings.first?.shortcut, try key(38))
    }

    func testSuspensionsComposeAndStopRejectsLatePressAndResult() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        var requests: [AudioSelectionRequest] = []
        let store = ShortcutStore(selectTarget: { _, request in requests.append(request) },
                                  preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        let token = try XCTUnwrap(registrar.registered.keys.first)
        store.setSuspended(.switching, true)
        store.setSuspended(.quitting, true)
        store.setSuspended(.quitting, false)
        registrar.onPress?(token) // Deliberately bypass the fake's delivery gate.
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(registrar.deliveryEnabled)
        store.setSuspended(.switching, false)
        registrar.onPress?(token)
        let request = try XCTUnwrap(requests.last)
        let lateCallback = registrar.onPress
        store.stop()
        store.stop()
        lateCallback?(token)
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(store.handleSelectionResult(.init(request: request, outcome: .failed("late"))))
        XCTAssertEqual(registrar.closes, 1)
    }

    func testOfflineSynchronousFailureIsForwardedOnceAndSuccessIsQuiet() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        var store: ShortcutStore!
        var lastRequest: AudioSelectionRequest?
        var failures = 0
        store = ShortcutStore(selectTarget: { received, request in
            XCTAssertEqual(received, saved.target)
            lastRequest = request
            if store.handleSelectionResult(.init(request: request, outcome: .failed("Offline"))) { failures += 1 }
        }, preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        registrar.onPress?(try XCTUnwrap(registrar.registered.keys.first))
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(store.message, "Offline")
        XCTAssertFalse(store.handleSelectionResult(.init(request: try XCTUnwrap(lastRequest), outcome: .failed("Duplicate"))))
        XCTAssertFalse(store.handleSelectionResult(.init(request: .init(origin: .pointer), outcome: .selected)))
    }

    func testEditedBindingRejectsOldSelectionFailure() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        var request: AudioSelectionRequest?
        let store = ShortcutStore(selectTarget: { _, value in request = value }, preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        registrar.onPress?(try XCTUnwrap(registrar.registered.keys.first))
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(store.commitRecording(try key(38)))
        await store.drain()
        XCTAssertFalse(store.handleSelectionResult(.init(request: try XCTUnwrap(request), outcome: .failed("Old"))))
        XCTAssertNotEqual(store.message, "Old")
    }

    func testInvalidConfigurationDisablesEditingAndNeverOverwrites() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.failLoad = true
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        store.updateDevices([device(target)])
        await store.drain()
        XCTAssertFalse(store.canEdit)
        XCTAssertFalse(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertEqual(prefs.saves, 0)
        XCTAssertTrue(registrar.registered.isEmpty)
        XCTAssertEqual(store.footerMessage, ShortcutError.invalidConfiguration.localizedDescription)
        XCTAssertEqual(store.recoveryTitle, expectedLocalized("Reload", "重新读取"))
        let initialFailure = store.failureEvent
        store.updateDevices([device(target)])
        XCTAssertEqual(store.failureEvent, initialFailure)
        store.retryRecovery()
        await store.drain()
        XCTAssertNotEqual(store.failureEvent?.id, initialFailure?.id,
                          "An explicit read retry that fails again is a new event even with the same reason.")
    }

    func testSingleFailedUnregistrationDoesNotDisableUnrelatedBinding() async throws {
        let first = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let second = ShortcutBinding(target: .hal(uid: "b"), shortcut: try key(38), lastKnownName: "Other")
        prefs.bindings = [first, second]
        var selected: [AudioTargetIdentity] = []
        let store = ShortcutStore(selectTarget: { target, _ in selected.append(target) },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")],
                            discovery: .init(hal: .init(observedIdentifiers: ["complete-uid-a"], isComplete: true)))
        store.start()
        await store.drain()
        registrar.refusedCleanup = [first.shortcut]
        XCTAssertFalse(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertEqual(store.registrationStates[second.id], .registered)
        let secondToken = try XCTUnwrap(registrar.registered.first(where: { $0.value == second.shortcut })?.key)
        registrar.onPress?(secondToken)
        XCTAssertEqual(selected, [second.target])
        let deletion = try XCTUnwrap(store.requestRecordRemoval(bindingID: second.id))
        XCTAssertTrue(store.confirmDeletion(deletion))
        await store.drain()
        XCTAssertEqual(store.bindings, [first])
    }

    func testSuccessfulCurrentResultDoesNotPublishFailure() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        var store: ShortcutStore!
        store = ShortcutStore(selectTarget: { _, request in
            XCTAssertFalse(store.handleSelectionResult(.init(request: request, outcome: .selected)))
        }, preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        registrar.onPress?(try XCTUnwrap(registrar.registered.keys.first))
        XCTAssertNil(store.selectionFailure)
        XCTAssertNil(store.message)
        XCTAssertNil(store.failureEvent)
    }

    func testOfflineRegistrationFailureHasEventsForExplicitRetriesWithoutDirectoryReplay() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        registrar.refused = [saved.shortcut]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Registration recovery must not select output") },
                                  preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        let first = try XCTUnwrap(store.failureEvent)
        XCTAssertNotNil(store.rowIssue(for: saved.target))
        XCTAssertEqual(store.recoveryTitle, expectedLocalized("Retry Registration", "重试注册"))
        store.updateDevices([])
        await store.drain()
        XCTAssertEqual(store.failureEvent, first)
        store.retryRecovery()
        let repeated = try XCTUnwrap(store.failureEvent)
        XCTAssertNotEqual(repeated.id, first.id)
        XCTAssertEqual(repeated.message, first.message)
        registrar.refused = []
        store.retryRecovery()
        XCTAssertNil(store.rowIssue(for: saved.target))
        XCTAssertNil(store.recoveryTitle)
        XCTAssertEqual(store.failureEvent, repeated, "Successful registration emits no failure event.")
        XCTAssertEqual(prefs.saves, 0)
        store.stop()
    }

    func testHeldLoadKeepsMainActorResponsiveAndStopRejectsLateRegistration() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar(), barrier = ShortcutIOBarrier()
        prefs.bindings = [try binding()]
        prefs.loadBarrier = barrier
        defer { barrier.release() }
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Loading cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.start()
        XCTAssertEqual(store.message, expectedLocalized("Loading shortcuts…", "正在读取快捷键…"))
        XCTAssertFalse(store.canEdit)
        await barrier.waitUntilEntered()
        store.updateDevices([device(target)])
        XCTAssertFalse(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(registrar.registered.isEmpty)
        var drained = false
        let waiting = Task { await store.drain(); drained = true }
        await Task.yield()
        XCTAssertFalse(drained)
        store.stop()
        barrier.release()
        await waiting.value
        XCTAssertTrue(drained)
        XCTAssertTrue(store.bindings.isEmpty)
        XCTAssertEqual(registrar.registrationCalls, 0)
        XCTAssertEqual(registrar.closes, 1)
        XCTAssertEqual(prefs.saveAttempts, 0)
        store.start()
        store.retryRecovery()
        XCTAssertEqual(prefs.loads, 1)
    }

    func testLoadFinishingDuringQuitWaitsUntilCancellationToRegister() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar(), barrier = ShortcutIOBarrier()
        prefs.bindings = [try binding()]
        prefs.loadBarrier = barrier
        defer { barrier.release() }
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.start()
        await barrier.waitUntilEntered()
        store.setSuspended(.quitting, true)
        barrier.release()
        await store.drain()
        XCTAssertEqual(store.bindings, prefs.bindings)
        XCTAssertTrue(registrar.registered.isEmpty)
        XCTAssertFalse(store.canEdit)
        store.setSuspended(.quitting, false)
        XCTAssertEqual(registrar.registered.count, 1)
        XCTAssertTrue(registrar.deliveryEnabled)
    }

    func testFailedLoadCanBeExplicitlyRetriedWithoutSavingOrRestarting() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let saved = try binding()
        prefs.bindings = [saved]
        prefs.failLoad = true
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        XCTAssertEqual(store.recoveryTitle, expectedLocalized("Reload", "重新读取"))
        XCTAssertTrue(store.canRecover)
        prefs.failLoad = false
        let barrier = ShortcutIOBarrier()
        defer { barrier.release() }
        prefs.loadBarrier = barrier
        store.retryRecovery()
        store.retryRecovery()
        await barrier.waitUntilEntered()
        XCTAssertFalse(store.canRecover)
        XCTAssertEqual(prefs.loads, 2, "Repeated retry clicks must share one read.")
        barrier.release()
        await store.drain()
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertTrue(store.canEdit)
        XCTAssertNil(store.recoveryTitle)
        XCTAssertEqual(registrar.registered.count, 1)
        XCTAssertEqual(prefs.saveAttempts, 0)
    }

    func testRetryRegistrationPreservesHealthyTokenAndDoesNotWritePreferences() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let first = try binding()
        let second = ShortcutBinding(target: .hal(uid: "other"), shortcut: try key(38), lastKnownName: "Other")
        prefs.bindings = [first, second]
        registrar.refused = [second.shortcut]
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        let healthy = try XCTUnwrap(registrar.registered.first { $0.value == first.shortcut }?.key)
        XCTAssertEqual(store.recoveryTitle, expectedLocalized("Retry Registration", "重试注册"))
        store.setSuspended(.quitting, true)
        store.retryRecovery()
        XCTAssertEqual(registrar.registrationCalls, 2)
        registrar.refused = []
        store.setSuspended(.quitting, false)
        // Quit cancellation is itself an explicit restoration boundary.
        XCTAssertEqual(registrar.registered[healthy], first.shortcut)
        XCTAssertEqual(registrar.registrationCalls, 3)
        XCTAssertNil(store.recoveryTitle)
        XCTAssertEqual(prefs.saveAttempts, 0)

        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        registrar.refused = [second.shortcut]
        store.cancelRecording()
        let restoredHealthy = try XCTUnwrap(registrar.registered.first { $0.value == first.shortcut }?.key)
        registrar.refused = []
        let callsBefore = registrar.registrationCalls
        store.retryRecovery()
        XCTAssertEqual(registrar.registrationCalls, callsBefore + 1)
        XCTAssertEqual(registrar.registered[restoredHealthy], first.shortcut)
        XCTAssertNil(store.recoveryTitle)
        XCTAssertEqual(prefs.saveAttempts, 0)
    }

    func testAcceptedSaveFinishesThroughRecordingCancelAndReversibleQuit() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar(), barrier = ShortcutIOBarrier()
        let saved = try binding()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Saving cannot select") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        prefs.saveBarrier = barrier
        defer { barrier.release() }
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(store.commitRecording(try key(38)))
        XCTAssertFalse(store.isRecording)
        XCTAssertFalse(store.canEdit)
        XCTAssertEqual(store.message, expectedLocalized("Saving shortcuts…", "正在保存快捷键…"))
        XCTAssertEqual(store.bindings, [saved])
        await barrier.waitUntilEntered()
        store.cancelRecording()
        store.setSuspended(.quitting, true)
        let callsBefore = registrar.registrationCalls
        barrier.release()
        await store.drain()
        XCTAssertEqual(store.bindings.first?.shortcut, try key(38))
        XCTAssertEqual(prefs.bindings, store.bindings)
        XCTAssertFalse(registrar.deliveryEnabled)
        XCTAssertEqual(registrar.registrationCalls, callsBefore)
        store.setSuspended(.quitting, false)
        XCTAssertTrue(registrar.deliveryEnabled)
        XCTAssertEqual(registrar.registrationCalls, callsBefore)
    }

    func testSaveFailureDuringQuitDefersRestorationUntilQuitIsCancelled() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar(), barrier = ShortcutIOBarrier()
        let saved = try binding()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        prefs.saveBarrier = barrier
        prefs.failSave = true
        defer { barrier.release() }
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(store.commitRecording(try key(38)))
        await barrier.waitUntilEntered()
        store.setSuspended(.quitting, true)
        let callsBefore = registrar.registrationCalls
        barrier.release()
        await store.drain()
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.bindings, [saved])
        XCTAssertTrue(registrar.registered.isEmpty)
        XCTAssertEqual(registrar.registrationCalls, callsBefore)
        store.setSuspended(.quitting, false)
        XCTAssertEqual(Set(registrar.registered.values), [saved.shortcut])
        XCTAssertEqual(registrar.registrationCalls, callsBefore + 1)
        XCTAssertTrue(registrar.deliveryEnabled)
    }

    func testStopDrainsAcceptedReplacementWithoutLateRegistrationOnEitherFileOutcome() async throws {
        for failSave in [false, true] {
            let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar(), barrier = ShortcutIOBarrier()
            let saved = try binding()
            prefs.bindings = [saved]
            let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
            store.updateDevices([device(target, name: "Speakers")])
            store.start()
            await store.drain()
            prefs.saveBarrier = barrier
            prefs.failSave = failSave
            defer { barrier.release() }
            XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
            XCTAssertTrue(store.commitRecording(try key(38)))
            await barrier.waitUntilEntered()
            store.stop()
            let callsBefore = registrar.registrationCalls
            var drained = false
            let waiting = Task { await store.drain(); drained = true }
            waiting.cancel()
            await Task.yield()
            XCTAssertFalse(drained, "Task cancellation cannot finish physical storage.")
            barrier.release()
            await waiting.value
            XCTAssertTrue(drained)
            XCTAssertEqual(prefs.bindings.first?.shortcut, try key(failSave ? 40 : 38))
            XCTAssertEqual(store.bindings, [saved], "Closed Store must not publish a late success.")
            XCTAssertTrue(registrar.registered.isEmpty)
            XCTAssertEqual(registrar.registrationCalls, callsBefore)
            XCTAssertEqual(registrar.closes, 1)
            XCTAssertFalse(store.canEdit)
        }
    }

    func testStopDrainsConfirmedDeletionWithoutRollingBackCompletedDiskWrite() async throws {
        for failSave in [false, true] {
            let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar(), barrier = ShortcutIOBarrier()
            let saved = try binding()
            prefs.bindings = [saved]
            let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
            store.updateDevices([], discovery: .init(hal: .init(isComplete: true)))
            store.start()
            await store.drain()
            prefs.saveBarrier = barrier
            prefs.failSave = failSave
            defer { barrier.release() }
            let request = try XCTUnwrap(store.requestRecordRemoval(bindingID: saved.id))
            XCTAssertTrue(store.confirmDeletion(request))
            await barrier.waitUntilEntered()
            store.stop()
            let callsBefore = registrar.registrationCalls
            barrier.release()
            await store.drain()
            XCTAssertEqual(prefs.bindings, failSave ? [saved] : [])
            XCTAssertTrue(registrar.registered.isEmpty)
            XCTAssertEqual(registrar.registrationCalls, callsBefore)
            XCTAssertEqual(prefs.saveAttempts, 1)
            XCTAssertFalse(store.confirmDeletion(request))
        }
    }

    func testAudioShutdownUsesCoordinatorToDrainAcceptedPreferenceWriteBeforeRelease() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar(), barrier = ShortcutIOBarrier()
        prefs.bindings = [try binding()]
        let shortcuts = ShortcutStore(selectTarget: { _, _ in XCTFail("Shutdown cannot select") },
                                      preferences: prefs, registrar: registrar)
        shortcuts.start()
        await shortcuts.drain()
        let routes = ShortcutShutdownRoutes()
        let audio = AudioStore(hardware: ShortcutShutdownHardware(), routes: routes)
        let volume = AudioVolumeStore(provider: ShortcutShutdownVolume(), resolveTarget: { _ in
            throw AudioVolumeIssue.closed
        })
        let coordinator = AudioInteractionCoordinator(audio: audio, shortcuts: shortcuts, volume: volume)
        prefs.saveBarrier = barrier
        defer { barrier.release() }
        shortcuts.updateDevices([device(target, name: "Speakers")])
        XCTAssertTrue(shortcuts.beginRecording(target: target, deviceName: "Speakers"))
        XCTAssertTrue(shortcuts.commitRecording(try key(38)))
        await barrier.waitUntilEntered()
        audio.stop()
        XCTAssertEqual(registrar.closes, 1, "Normal shutdown must close shortcut admission synchronously.")
        var finished = false
        let shutdown = Task { try await audio.shutdown(); finished = true }
        await Task.yield()
        XCTAssertFalse(finished)
        XCTAssertFalse(routes.stopped)
        barrier.release()
        try await shutdown.value
        XCTAssertTrue(finished)
        XCTAssertTrue(routes.stopped)
        XCTAssertTrue(coordinator.volume.isClosed)
        XCTAssertEqual(prefs.bindings.first?.shortcut, try key(38))
        XCTAssertTrue(registrar.registered.isEmpty)
    }

    func testNameWritesCoalesceLatestDirectoryWithoutChangingIdentityOrBlockingHotKeys() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar(), barrier = ShortcutIOBarrier()
        let saved = try binding()
        prefs.bindings = [saved]
        var selections = 0
        let store = ShortcutStore(selectTarget: { _, _ in selections += 1 }, preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        let token = try XCTUnwrap(registrar.registered.keys.first)
        prefs.saveBarrier = barrier
        defer { barrier.release() }
        store.updateDevices([device(target, name: "First")])
        await barrier.waitUntilEntered()
        for _ in 0..<20 { store.updateDevices([device(target, name: "Latest")]) }
        XCTAssertEqual(prefs.saveAttempts, 1)
        XCTAssertFalse(store.canEdit)
        XCTAssertTrue(registrar.deliveryEnabled)
        registrar.onPress?(token)
        XCTAssertEqual(selections, 1)
        barrier.release()
        await store.drain()
        XCTAssertEqual(prefs.saveAttempts, 2)
        XCTAssertEqual(store.bindings.first?.lastKnownName, "Latest")
        XCTAssertEqual(store.bindings.first?.revision, saved.revision)
        XCTAssertEqual(store.bindings.first?.target, saved.target)
        XCTAssertEqual(registrar.registered[token], saved.shortcut)
        XCTAssertTrue(store.canEdit)
    }

    func testFailedNameSaveDoesNotRetryOnPollingAndExplicitRecoverySavesLatestName() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let saved = try binding()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.start()
        await store.drain()
        prefs.failSave = true
        store.updateDevices([device(target)])
        await store.drain()
        XCTAssertEqual(prefs.saveAttempts, 1)
        for _ in 0..<25 {
            store.updateDevices([device(target)])
            await store.drain()
        }
        XCTAssertEqual(prefs.saveAttempts, 1)
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(store.recoveryTitle, expectedLocalized("Retry Save", "重试保存"))
        XCTAssertTrue(store.footerMessage?.contains(expectedLocalized("The device name cache was not saved", "设备名称缓存未保存")) == true)
        XCTAssertTrue(store.canRecover)
        XCTAssertTrue(registrar.deliveryEnabled)
        prefs.failSave = false
        store.retryRecovery()
        await store.drain()
        XCTAssertEqual(prefs.saveAttempts, 2)
        XCTAssertEqual(prefs.bindings.first?.lastKnownName, "Renamed Speakers")
        XCTAssertNil(store.recoveryTitle)
        XCTAssertNil(store.message)
    }

    func testReplacementAfterFailedRenamePersistsCurrentNameWithNewRevision() async throws {
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let saved = try binding()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in }, preferences: prefs, registrar: registrar)
        store.updateDevices([device(target, name: "Speakers")])
        store.start()
        await store.drain()
        prefs.failSave = true
        store.updateDevices([device(target)])
        await store.drain()
        prefs.failSave = false
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Renamed Speakers"))
        XCTAssertTrue(store.commitRecording(try key(38)))
        await store.drain()
        XCTAssertEqual(prefs.saveAttempts, 2)
        XCTAssertEqual(store.bindings.first?.lastKnownName, "Renamed Speakers")
        XCTAssertEqual(store.bindings.first?.shortcut, try key(38))
        XCTAssertNotEqual(store.bindings.first?.revision, saved.revision)
        XCTAssertEqual(prefs.bindings, store.bindings)
        XCTAssertNil(store.recoveryTitle)
    }
}

@MainActor
final class ShortcutTestPreferences: ShortcutPreferencesProviding {
    var bindings: [ShortcutBinding] = []
    var isMissing = false
    var loads = 0, saves = 0
    var saveAttempts = 0
    var failLoad = false, failSave = false
    var loadBarrier: ShortcutIOBarrier?
    var saveBarrier: ShortcutIOBarrier?
    func load() async throws -> [ShortcutBinding]? {
        loads += 1
        await loadBarrier?.wait()
        if failLoad { throw ShortcutError.invalidConfiguration }
        return isMissing ? nil : bindings
    }
    func save(_ bindings: [ShortcutBinding]) async throws {
        saveAttempts += 1
        await saveBarrier?.wait()
        if failSave { throw ShortcutError.unavailable("Save failed") }
        saves += 1
        self.bindings = bindings
        isMissing = false
    }
}

@MainActor
final class ShortcutTestRegistrar: GlobalShortcutRegistering {
    var onPress: ((GlobalShortcutRegistration) -> Void)?
    var registered: [GlobalShortcutRegistration: DeviceShortcut] = [:]
    var orphans: Set<DeviceShortcut> = []
    var system: Set<DeviceShortcut> = []
    var failUnregister = false, failSystemQuery = false
    var refused: Set<DeviceShortcut> = []
    var refusedCleanup: Set<DeviceShortcut> = []
    var deliveryEnabled = false
    var closes = 0
    var registrationCalls = 0
    func register(_ shortcut: DeviceShortcut) throws -> GlobalShortcutRegistration {
        registrationCalls += 1
        try retryFailedCleanup(for: shortcut)
        guard !refused.contains(shortcut), !registered.values.contains(shortcut) else {
            throw ShortcutError.registration(operation: "register", status: -9878)
        }
        let token = GlobalShortcutRegistration()
        registered[token] = shortcut
        return token
    }
    func unregister(_ registration: GlobalShortcutRegistration) throws {
        guard let shortcut = registered.removeValue(forKey: registration) else { return }
        if failUnregister || refusedCleanup.contains(shortcut) {
            orphans.insert(shortcut)
            throw ShortcutError.unavailable("Unregister failed")
        }
    }
    func retryFailedCleanup(for shortcut: DeviceShortcut?) throws {
        let matching = orphans.filter { shortcut == nil || $0 == shortcut }
        if (failUnregister && !matching.isEmpty) || !refusedCleanup.intersection(matching).isEmpty {
            throw ShortcutError.unavailable("Cleanup still failed")
        }
        orphans.subtract(matching)
    }
    func systemShortcuts() throws -> Set<DeviceShortcut> {
        if failSystemQuery { throw ShortcutError.unavailable("System query failed") }
        return system
    }
    func setDeliveryEnabled(_ enabled: Bool) { deliveryEnabled = enabled }
    func close() throws { closes += 1; registered.removeAll(); onPress = nil }
}

@MainActor
final class ShortcutIOBarrier {
    private var released = false
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiting = continuation
            entered = true
            let observers = entryWaiters
            entryWaiters.removeAll()
            for observer in observers { observer.resume() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

private struct ShortcutShutdownHardware: AudioHardwareProviding {
    func beginShutdown() {}
    func snapshot() async throws -> CoreAudioSnapshot {
        .init(devices: [], currentDeviceID: nil, systemSoundDeviceID: nil, warnings: [])
    }
    func select(uid: String) async throws { throw AudioServiceError.unavailable("Unexpected selection") }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {}
    func stopObserving() async {}
}

@MainActor
private final class ShortcutShutdownRoutes: PrivateRouting {
    var onChange: (() -> Void)?
    var stopped = false
    func start() {}
    func stop() { stopped = true }
    func beginShutdown() {}
    func snapshot() -> PrivateRouteSnapshot { .init(routes: [], warning: nil, diagnostics: "shortcut shutdown fixture") }
    func select(identifier: String) async throws { throw AudioServiceError.unavailable("Unexpected selection") }
    func prepareToLeave() async throws { throw AudioServiceError.unavailable("Unexpected route write") }
    func completedLeave() async throws { throw AudioServiceError.unavailable("Unexpected route write") }
}

private struct ShortcutShutdownVolume: AudioVolumeProviding {
    func readVolume(for target: AudioVolumeTarget) async throws -> AudioVolumeSnapshot { throw AudioVolumeIssue.closed }
    func setVolume(_ value: Float, for target: AudioVolumeTarget, permit: AudioMutationPermit) async throws -> AudioVolumeWriteResult {
        throw AudioVolumeIssue.closed
    }
    func observeVolumeChanges(targets: [AudioVolumeTarget], changed: @escaping @Sendable () -> Void) async throws {}
    func stopObservingVolume() async {}
}
