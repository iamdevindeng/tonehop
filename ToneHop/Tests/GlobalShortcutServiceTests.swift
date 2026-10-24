import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ToneHop

@MainActor
final class GlobalShortcutServiceTests: XCTestCase {
    private func key() throws -> DeviceShortcut { try .init(keyCode: 40, modifiers: .command) }

    func testHeldGestureIsOnceAndInterruptedReleaseIsReconciled() throws {
        let runtime = ShortcutTestRuntime()
        let subject = GlobalShortcutService(runtime: runtime)
        var count = 0
        subject.onPress = { _ in count += 1 }
        _ = try subject.register(key())
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(count, 1)
        subject.setDeliveryEnabled(false)
        subject.setDeliveryEnabled(true) // Still physically held on wake.
        runtime.handler?(1, .pressed)
        XCTAssertEqual(count, 1)
        subject.setDeliveryEnabled(false)
        runtime.pressed.remove(40) // Released during sleep; no Released event.
        subject.setDeliveryEnabled(true)
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(count, 2)
        runtime.handler?(1, .released)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(count, 3)
    }

    func testMissedHotKeyReleaseIsReconciledFromPhysicalState() async throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        defer { try? service.close() }
        var presses = 0
        service.onPress = { _ in presses += 1 }
        _ = try service.register(key())
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 1)
        await waitForKeyStateRead(runtime, pressed: true)
        runtime.keyReleaseHandler?(38)
        runtime.handler?(1, .pressed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 1, "Physical observation and an unrelated release cannot unlock a held gesture.")

        runtime.pressed.remove(40) // Neither Carbon nor raw key-up delivers a release.
        await waitForKeyStateRead(runtime, pressed: false)
        XCTAssertEqual(presses, 1, "Observing release cannot submit another selection.")
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 2, "The first deliberate press after the missed release works exactly once.")
    }

    func testHeldKeyObserverStopsAfterReleaseAndOnClose() async throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        defer { try? service.close() }
        _ = try service.register(key())
        let readyReads = runtime.keyStateReads
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runtime.keyStateReads, readyReads, "Ready entries do not need a physical observer.")

        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        await waitForKeyStateRead(runtime, pressed: true)
        runtime.pressed.remove(40)
        await waitForKeyStateRead(runtime, pressed: false)
        let releasedReads = runtime.keyStateReads
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runtime.keyStateReads, releasedReads, "The observer stops when every entry is ready.")

        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        await waitForKeyStateRead(runtime, pressed: true)
        try service.close()
        let closedReads = runtime.keyStateReads
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runtime.keyStateReads, closedReads, "Closing cancels observation of a physically held key.")
    }

    func testPhysicalReleaseIsObservedWhileDeliveryIsDisabled() async throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        defer { try? service.close() }
        var presses = 0
        service.onPress = { _ in presses += 1 }
        _ = try service.register(key())
        service.setDeliveryEnabled(false)
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        await waitForKeyStateRead(runtime, pressed: true)
        runtime.pressed.remove(40)
        await waitForKeyStateRead(runtime, pressed: false)
        XCTAssertEqual(presses, 0)

        // The new key-down precedes enabling, so its synchronous state check
        // cannot compensate for failing to observe the preceding release.
        runtime.pressed.insert(40)
        service.setDeliveryEnabled(true)
        runtime.handler?(1, .pressed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 1)
    }

    private func waitForKeyStateRead(_ runtime: ShortcutTestRuntime, pressed: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        let observed = expectation(description: "Physical observer reads key 40 as \(pressed ? "held" : "released")")
        runtime.onKeyStateRead = { code, isPressed in
            guard code == 40, isPressed == pressed else { return }
            runtime.onKeyStateRead = nil
            observed.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [observed], timeout: 2)
        runtime.onKeyStateRead = nil
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    func testUnregisteredTokenNeverDeliversAndNativeCleanupCanRetry() throws {
        let runtime = ShortcutTestRuntime()
        let subject = GlobalShortcutService(runtime: runtime)
        var count = 0
        subject.onPress = { _ in count += 1 }
        let token = try subject.register(key())
        runtime.failUnregister = true
        XCTAssertThrowsError(try subject.unregister(token))
        runtime.handler?(1, .pressed)
        XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try subject.retryFailedCleanup(for: nil))
        runtime.failUnregister = false
        _ = try subject.register(key())
        runtime.handler?(1, .pressed)
        runtime.handler?(2, .pressed)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(runtime.liveIDs, [2])
    }

    func testHandlerFailureDoesNotRegisterAndCloseBlocksLateCallback() throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        runtime.failInstall = true
        XCTAssertThrowsError(try service.register(key()))
        XCTAssertTrue(runtime.liveIDs.isEmpty)
        runtime.failInstall = false
        var count = 0
        service.onPress = { _ in count += 1 }
        _ = try service.register(key())
        let late = runtime.handler
        try service.close()
        late?(1, .pressed)
        XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try service.register(key()))
    }

    func testUnrelatedNativeCleanupFailureDoesNotBlockAnotherCombination() throws {
        let runtime = ShortcutTestRuntime(), first = try key()
        let second = try DeviceShortcut(keyCode: 38, modifiers: .command)
        let service = GlobalShortcutService(runtime: runtime)
        let token = try service.register(first)
        runtime.failUnregister = true
        XCTAssertThrowsError(try service.unregister(token))
        _ = try service.register(second)
        var received = 0
        service.onPress = { _ in received += 1 }
        runtime.handler?(1, .pressed)
        runtime.handler?(2, .pressed)
        XCTAssertEqual(received, 1)
    }

    func testKeyHeldWhileRegisteringCannotTriggerTheRecordingGesture() throws {
        let runtime = ShortcutTestRuntime()
        let subject = GlobalShortcutService(runtime: runtime)
        runtime.pressed.insert(40)
        _ = try subject.register(key())
        var presses = 0
        subject.onPress = { _ in presses += 1 }
        subject.setDeliveryEnabled(true)
        runtime.handler?(1, .pressed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 0)
        runtime.pressed.remove(40)
        runtime.handler?(1, .released)
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 1)
    }

    func testRecordingKeyRawReleaseArmsFirstPressWithoutHotKeyRelease() throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        defer { try? service.close() }
        var presses = 0
        service.onPress = { _ in presses += 1 }
        service.setDeliveryEnabled(false)
        runtime.pressed.insert(40)
        _ = try service.register(key())
        service.setDeliveryEnabled(true) // Saving finished before the recording gesture ended.
        runtime.handler?(1, .pressed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 0)

        runtime.pressed.remove(40)
        runtime.keyReleaseHandler?(40) // The pre-registration down has no Carbon hot-key release.
        XCTAssertEqual(presses, 0, "Observing a release must never select audio.")
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 1, "The first deliberate press after recording must work exactly once.")
    }

    func testUnrelatedRawReleaseDoesNotUnlockRecordingGesture() throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        defer { try? service.close() }
        var presses = 0
        service.onPress = { _ in presses += 1 }
        runtime.pressed.insert(40)
        _ = try service.register(key())
        runtime.keyReleaseHandler?(38)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 0)
        runtime.pressed.remove(40)
        runtime.keyReleaseHandler?(40)
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 1)
    }

    func testPhysicalReleaseWithoutAnyReleaseEventArmsFirstPress() async throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        defer { try? service.close() }
        var presses = 0
        service.onPress = { _ in presses += 1 }
        runtime.pressed.insert(40)
        _ = try service.register(key())
        service.setDeliveryEnabled(true)
        let stillHeld = expectation(description: "Physical observer checks the held recording key")
        runtime.onKeyStateRead = { code, isPressed in
            guard code == 40, isPressed else { return }
            runtime.onKeyStateRead = nil
            stillHeld.fulfill()
        }
        let heldResult = await XCTWaiter.fulfillment(of: [stillHeld], timeout: 2)
        XCTAssertEqual(heldResult, .completed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 0, "Waiting must not turn a long recording hold into a selection.")

        let released = expectation(description: "Physical observer sees release after focus moved elsewhere")
        runtime.pressed.remove(40)
        runtime.onKeyStateRead = { code, isPressed in
            guard code == 40, !isPressed else { return }
            runtime.onKeyStateRead = nil
            released.fulfill()
        }
        let releaseResult = await XCTWaiter.fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(releaseResult, .completed)
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(presses, 1)
    }

    func testAsyncRecordingSaveCompletesWhileHeldAndFirstFollowingPressSelects() async throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        let preferences = ShortcutTestPreferences()
        let target = AudioTargetIdentity.hal(uid: "new-recording-device")
        var selections: [AudioTargetIdentity] = []
        let store = ShortcutStore(selectTarget: { selected, _ in selections.append(selected) },
                                  preferences: preferences, registrar: service)
        defer { store.stop() }
        store.updateDevices([AudioDevice(id: "new-recording-device", name: "Speakers", transport: .speaker,
                                          backend: .coreAudio(uid: "new-recording-device"), shortcutTarget: target)])
        store.start()
        await store.drain()
        let barrier = ShortcutIOBarrier()
        defer { barrier.release() }
        preferences.saveBarrier = barrier
        XCTAssertTrue(store.beginRecording(target: target, deviceName: "Speakers"))
        runtime.pressed.insert(40)
        XCTAssertTrue(store.commitRecording(try key()))
        await barrier.waitUntilEntered()
        runtime.handler?(1, .pressed)
        XCTAssertTrue(selections.isEmpty)
        barrier.release()
        await store.drain()
        XCTAssertEqual(store.bindings.first?.shortcut, try key())
        XCTAssertEqual(preferences.bindings, store.bindings)
        XCTAssertTrue(store.canEdit)
        runtime.handler?(1, .pressed)
        XCTAssertTrue(selections.isEmpty, "Saving cannot reuse the still-held recording gesture.")

        runtime.pressed.remove(40)
        runtime.keyReleaseHandler?(40)
        runtime.pressed.insert(40)
        runtime.handler?(1, .pressed)
        runtime.handler?(1, .pressed)
        XCTAssertEqual(selections, [target])
    }

    func testUnregisterAndCloseRejectLateRecordingReleaseCallbacks() throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        runtime.pressed.insert(40)
        let old = try service.register(key())
        let lateRelease = runtime.keyReleaseHandler
        let lateHotKey = runtime.handler
        var presses = 0
        service.onPress = { _ in presses += 1 }
        try service.unregister(old)
        runtime.pressed.remove(40)
        lateRelease?(40)
        lateHotKey?(1, .pressed)
        XCTAssertEqual(presses, 0)
        XCTAssertTrue(runtime.liveIDs.isEmpty)

        _ = try service.register(key())
        lateHotKey?(1, .pressed)
        runtime.pressed.insert(40)
        lateHotKey?(2, .pressed)
        XCTAssertEqual(presses, 1)
        try service.close()
        lateRelease?(40)
        lateHotKey?(2, .released)
        lateHotKey?(2, .pressed)
        XCTAssertEqual(presses, 1)
        XCTAssertTrue(runtime.liveIDs.isEmpty)
    }

    func testClosingInitialHoldStopsPhysicalObservation() async throws {
        let runtime = ShortcutTestRuntime()
        let service = GlobalShortcutService(runtime: runtime)
        runtime.pressed.insert(40)
        _ = try service.register(key())
        let observed = expectation(description: "Initial hold observation started")
        runtime.onKeyStateRead = { _, _ in
            runtime.onKeyStateRead = nil
            observed.fulfill()
        }
        let startedResult = await XCTWaiter.fulfillment(of: [observed], timeout: 2)
        XCTAssertEqual(startedResult, .completed)
        try service.close()
        let afterClose = expectation(description: "No physical reads after close")
        afterClose.isInverted = true
        runtime.onKeyStateRead = { _, _ in afterClose.fulfill() }
        let stoppedResult = await XCTWaiter.fulfillment(of: [afterClose], timeout: 0.05)
        XCTAssertEqual(stoppedResult, .completed)
        runtime.onKeyStateRead = nil
    }

    func testRecorderNavigationAndClearAreSeparateFromModifiedKeys() throws {
        XCTAssertEqual(try ShortcutRecordingInput.decode(keyCode: 48, flags: [], isRepeat: false), .navigate)
        XCTAssertEqual(try ShortcutRecordingInput.decode(keyCode: 48, flags: .shift, isRepeat: false), .navigate)
        XCTAssertEqual(try ShortcutRecordingInput.decode(keyCode: 48, flags: .control, isRepeat: false),
                       .shortcut(try .init(keyCode: 48, modifiers: .control)))
        XCTAssertEqual(try ShortcutRecordingInput.decode(keyCode: 53, flags: [], isRepeat: false), .cancel)
        XCTAssertEqual(try ShortcutRecordingInput.decode(keyCode: 51, flags: [], isRepeat: false), .clear)
        XCTAssertEqual(try ShortcutRecordingInput.decode(keyCode: 51, flags: [], isRepeat: true), .ignore)
        XCTAssertThrowsError(try ShortcutRecordingInput.decode(keyCode: 51, flags: .function, isRepeat: false))
        XCTAssertThrowsError(try ShortcutRecordingInput.decode(keyCode: 117, flags: [], isRepeat: false))
        XCTAssertEqual(try ShortcutRecordingInput.decode(keyCode: 51, flags: .command, isRepeat: false),
                       .shortcut(try .init(keyCode: 51, modifiers: .command)))
        XCTAssertEqual(try ShortcutRecordingInput.decode(keyCode: 40, flags: .command, isRepeat: true), .ignore)
    }

    func testNativeRecorderBackspaceOnlyClearsDuringActiveCaptureAndEndsIt() async throws {
        let target = AudioTargetIdentity.hal(uid: "recorder-speakers")
        let saved = ShortcutBinding(target: target, shortcut: try key(), lastKnownName: "Speakers")
        let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.bindings = [saved]
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Key editing cannot select audio") },
                                  preferences: prefs, registrar: registrar)
        store.updateDevices([AudioDevice(id: "hal:recorder-speakers", name: "Speakers", transport: .speaker,
                                          backend: .coreAudio(uid: "recorder-speakers"), shortcutTarget: target)])
        store.start()
        await store.drain()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = ShortcutRecordingButton()
        button.frame = NSRect(x: 20, y: 20, width: 150, height: 30)
        button.shortcut = saved.shortcut
        button.onBegin = { store.beginRecording(target: target, deviceName: "Speakers") }
        button.onCancel = { store.cancelRecording() }
        button.onClear = { store.clearRecording() }
        button.onKey = { store.commitRecording($0) }
        window.contentView?.addSubview(button)
        defer {
            button.cancelSession()
            window.close()
            store.stop()
        }
        XCTAssertTrue(window.makeFirstResponder(button))
        let backspace = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{8}",
            charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: 51))
        XCTAssertFalse(button.performKeyEquivalent(with: backspace))
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.saveAttempts, 0)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        button.performClick(nil)
        button.keyDown(with: escape)
        XCTAssertFalse(button.recording)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.saveAttempts, 0)
        button.performClick(nil)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(button.recording)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.saveAttempts, 0)
        button.performClick(nil)
        XCTAssertTrue(button.recording)
        XCTAssertTrue(store.isRecording)
        XCTAssertTrue(window.firstResponder === button)
        button.keyDown(with: backspace)
        XCTAssertFalse(button.recording)
        XCTAssertFalse(store.isRecording)
        await store.drain()
        XCTAssertTrue(store.bindings.isEmpty)
        XCTAssertTrue(prefs.bindings.isEmpty)
        XCTAssertEqual(prefs.saveAttempts, 1)
        XCTAssertTrue(registrar.registered.isEmpty)
        XCTAssertFalse(button.performKeyEquivalent(with: backspace))
        XCTAssertEqual(prefs.saveAttempts, 1)
    }

    func testFailedInstallWithReferenceRemovesItAndReinstallsBeforeRegistering() throws {
        let calls = ShortcutTestCarbonCalls()
        let runtime = CarbonShortcutRuntime(calls: calls)
        let service = GlobalShortcutService(runtime: runtime)
        calls.installStatus = -50
        XCTAssertThrowsError(try service.register(key()))
        XCTAssertEqual(calls.installCount, 1)
        XCTAssertEqual(calls.removedHandlers.count, 1)
        XCTAssertEqual(calls.registerCount, 0)
        calls.installStatus = noErr
        _ = try service.register(key())
        XCTAssertEqual(calls.installCount, 2)
        XCTAssertEqual(calls.registerCount, 1)
        try service.close()
        XCTAssertEqual(calls.removedHandlers.count, 2)
        XCTAssertEqual(Set(calls.removedHandlers).count, 2)
    }

    func testNativeRawKeyReleaseDecodesOnlyValidKeysAndNeverConsumesInput() throws {
        let calls = ShortcutTestCarbonCalls()
        let runtime = CarbonShortcutRuntime(calls: calls)
        defer { try? runtime.close() }
        var releases: [UInt16] = []
        try runtime.installHandler({ _, _ in XCTFail("Raw input cannot become a registered hot-key press.") },
                                   onKeyRelease: { releases.append($0) })
        let callback = try XCTUnwrap(calls.callback)
        let context = try XCTUnwrap(calls.callbackContext)
        try withCarbonKeyEvent(kind: UInt32(kEventRawKeyUp), keyCode: 40) { event in
            XCTAssertEqual(callback(nil, event, context), OSStatus(eventNotHandledErr))
        }
        XCTAssertEqual(releases, [40])
        for kind in [kEventRawKeyDown, kEventRawKeyRepeat] {
            try withCarbonKeyEvent(kind: UInt32(kind), keyCode: 40) { event in
                XCTAssertEqual(callback(nil, event, context), OSStatus(eventNotHandledErr))
            }
        }
        let invalidCodes: [UInt32?] = [nil, UInt32(UInt16.max) + 1]
        for invalidCode in invalidCodes {
            try withCarbonKeyEvent(kind: UInt32(kEventRawKeyUp), keyCode: invalidCode) { event in
                XCTAssertEqual(callback(nil, event, context), OSStatus(eventNotHandledErr))
            }
        }
        XCTAssertEqual(releases, [40], "Unrelated or malformed native events must remain pass-through.")
    }

    func testNativeReleaseCallbackIsInertAfterUncertainHandlerRemoval() throws {
        let calls = ShortcutTestCarbonCalls()
        let runtime = CarbonShortcutRuntime(calls: calls)
        var releases = 0
        try runtime.installHandler({ _, _ in XCTFail("No hot-key input was sent.") },
                                   onKeyRelease: { _ in releases += 1 })
        let callback = try XCTUnwrap(calls.callback)
        let context = try XCTUnwrap(calls.callbackContext)
        // Failed removal deliberately preserves an inert callback box, making
        // invocation of the retained native callback valid after close.
        calls.removeStatus = -50
        XCTAssertThrowsError(try runtime.close())
        try withCarbonKeyEvent(kind: UInt32(kEventRawKeyUp), keyCode: 40) { event in
            XCTAssertEqual(callback(nil, event, context), OSStatus(eventNotHandledErr))
        }
        XCTAssertEqual(releases, 0)
        try runtime.close()
        XCTAssertEqual(calls.removedHandlers.count, 1)
    }

    private func withCarbonKeyEvent(kind: UInt32, keyCode: UInt32?, _ body: (EventRef) -> Void) throws {
        var created: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0,
                                   EventAttributes(kEventAttributeNone), &created), noErr)
        let event = try XCTUnwrap(created)
        defer { ReleaseEvent(event) }
        if var keyCode {
            XCTAssertEqual(SetEventParameter(event, UInt32(kEventParamKeyCode), UInt32(typeUInt32),
                                            MemoryLayout<UInt32>.size, &keyCode), noErr)
        }
        body(event)
    }

    func testRemoveFailureNeverReusesInvalidHandlerAndFailedInstallCannotBecomeUsable() throws {
        let calls = ShortcutTestCarbonCalls()
        var runtime: CarbonShortcutRuntime? = CarbonShortcutRuntime(calls: calls)
        calls.installStatus = -50
        calls.removeStatus = -50
        XCTAssertThrowsError(try runtime?.installHandler({ _, _ in }, onKeyRelease: { _ in }))
        XCTAssertThrowsError(try runtime?.installHandler({ _, _ in }, onKeyRelease: { _ in }))
        try runtime?.close()
        runtime = nil
        XCTAssertEqual(calls.installCount, 1)
        XCTAssertEqual(calls.removedHandlers.count, 1)

        let other = ShortcutTestCarbonCalls()
        var valid: CarbonShortcutRuntime? = CarbonShortcutRuntime(calls: other)
        try valid?.installHandler({ _, _ in }, onKeyRelease: { _ in })
        other.removeStatus = -50
        XCTAssertThrowsError(try valid?.close())
        try valid?.close()
        valid = nil
        XCTAssertEqual(other.removedHandlers.count, 1)
    }

    func testFailedRegisterWithReferenceIsCleanedAndMissingReferenceIsNotSuccess() throws {
        let calls = ShortcutTestCarbonCalls()
        let service = GlobalShortcutService(runtime: CarbonShortcutRuntime(calls: calls))
        calls.registerStatus = -50
        XCTAssertThrowsError(try service.register(key()))
        XCTAssertEqual(calls.unregistered.count, 1)
        calls.registerStatus = noErr
        calls.returnRegistration = false
        XCTAssertThrowsError(try service.register(key()))
        try service.close()
    }

    func testModifierNormalizationAcceptsFKeysButRejectsOptionOnlyAndSemanticFn() throws {
        XCTAssertThrowsError(try DeviceShortcut(keyCode: 40, modifiers: .option))
        XCTAssertThrowsError(try DeviceShortcut(keyCode: 40, modifiers: [.option, .shift]))
        XCTAssertThrowsError(try DeviceShortcut(keyCode: 57, modifiers: .command))
        XCTAssertThrowsError(try DeviceShortcut(keyCode: 72, modifiers: .control))
        XCTAssertThrowsError(try DeviceShortcut(keyCode: 40, appKitFlags: [.command, .function]))
        XCTAssertEqual(try DeviceShortcut(keyCode: 122, appKitFlags: [.command, .function]).modifiers, .command)
        XCTAssertEqual(try DeviceShortcut(keyCode: 123, appKitFlags: [.control, .function, .numericPad]).modifiers, .control)
        XCTAssertEqual(try DeviceShortcut(keyCode: 40, appKitFlags: [.command, .capsLock]).modifiers, .command)
    }
}

@MainActor
private final class ShortcutTestRuntime: ShortcutHotKeyRuntime {
    var handler: ((UInt32, ShortcutKeyPhase) -> Void)?
    var keyReleaseHandler: ((UInt16) -> Void)?
    var liveIDs: Set<UInt32> = []
    var pressed: Set<UInt16> = []
    var onKeyStateRead: ((UInt16, Bool) -> Void)?
    var keyStateReads = 0
    var failInstall = false, failUnregister = false
    func installHandler(_ handler: @escaping (UInt32, ShortcutKeyPhase) -> Void,
                        onKeyRelease: @escaping (UInt16) -> Void) throws {
        if failInstall { throw ShortcutError.unavailable("install failed") }
        self.handler = handler
        keyReleaseHandler = onKeyRelease
    }
    func register(_ shortcut: DeviceShortcut, eventID: UInt32) throws { liveIDs.insert(eventID) }
    func unregister(eventID: UInt32) throws {
        if failUnregister { throw ShortcutError.unavailable("unregister failed") }
        liveIDs.remove(eventID)
    }
    func systemShortcuts() throws -> Set<DeviceShortcut> { [] }
    func isKeyPressed(_ keyCode: UInt16) -> Bool {
        keyStateReads += 1
        let value = pressed.contains(keyCode)
        onKeyStateRead?(keyCode, value)
        return value
    }
    func close() throws { liveIDs.removeAll(); handler = nil; keyReleaseHandler = nil }
}

@MainActor
private final class ShortcutTestCarbonCalls: CarbonShortcutCalling {
    var installStatus: OSStatus = noErr, removeStatus: OSStatus = noErr, registerStatus: OSStatus = noErr
    var installCount = 0, registerCount = 0
    var returnRegistration = true
    var removedHandlers: [EventHandlerRef] = []
    var unregistered: [EventHotKeyRef] = []
    var callback: EventHandlerUPP?
    var callbackContext: UnsafeMutableRawPointer?
    func install(handler: EventHandlerUPP, context: UnsafeMutableRawPointer) -> (OSStatus, EventHandlerRef?) {
        installCount += 1
        callback = handler
        callbackContext = context
        return (installStatus, OpaquePointer(bitPattern: 0x1000 + installCount))
    }
    func remove(_ handler: EventHandlerRef) -> OSStatus {
        removedHandlers.append(handler)
        return removeStatus
    }
    func register(_ shortcut: DeviceShortcut, eventID: UInt32) -> (OSStatus, EventHotKeyRef?) {
        registerCount += 1
        return (registerStatus, returnRegistration ? OpaquePointer(bitPattern: 0x2000 + registerCount) : nil)
    }
    func unregister(_ reference: EventHotKeyRef) -> OSStatus { unregistered.append(reference); return noErr }
    func isKeyPressed(_ keyCode: UInt16) -> Bool { false }
}
