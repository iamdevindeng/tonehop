import XCTest
@testable import ToneHop

@MainActor
final class FirstLaunchShortcutTests: XCTestCase {
    private let speakerUID = "verified-built-in-speaker-uid"

    private func binding() throws -> ShortcutBinding {
        ShortcutBinding(target: .hal(uid: speakerUID),
                        shortcut: try DeviceShortcut(keyCode: 18, modifiers: [.control, .shift]),
                        lastKnownName: "Mac mini Speakers")
    }

    private func device() -> AudioDevice {
        AudioDevice(id: "hal:\(speakerUID)", name: "Mac mini Speakers", transport: .speaker,
                    backend: .coreAudio(uid: speakerUID), shortcutTarget: .hal(uid: speakerUID))
    }

    func testMissingConfigurationPersistsExactlyOneStarterBeforeRegisteringWithoutSelectingOutput() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let barrier = ShortcutIOBarrier()
        prefs.isMissing = true
        prefs.saveBarrier = barrier
        defer { barrier.release() }
        var providerCalls = 0
        let otherTarget = AudioTargetIdentity.hal(uid: "external-output-uid")
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("First launch must not switch output") },
                                  preferences: prefs, registrar: registrar, initialBinding: {
            providerCalls += 1
            return saved
        })
        store.updateDevices([device(), AudioDevice(id: "hal:external-output-uid", name: "External Speakers",
                            transport: .usb, backend: .coreAudio(uid: "external-output-uid"),
                            shortcutTarget: otherTarget)])
        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(prefs.loads, 0)
        store.start()
        await barrier.waitUntilEntered()
        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(prefs.saveAttempts, 1)
        XCTAssertTrue(store.bindings.isEmpty)
        XCTAssertEqual(registrar.registrationCalls, 0)
        XCTAssertFalse(registrar.deliveryEnabled)
        XCTAssertFalse(store.canEdit)
        barrier.release()
        await store.drain()
        store.start()
        await store.drain()
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(prefs.bindings, [saved])
        XCTAssertFalse(prefs.isMissing)
        XCTAssertNil(store.binding(for: otherTarget))
        XCTAssertEqual(Set(registrar.registered.values), [saved.shortcut])
        XCTAssertEqual(registrar.registrationCalls, 1)
        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(prefs.saves, 1)
        XCTAssertTrue(registrar.deliveryEnabled)
        store.stop()
    }

    func testExistingNonemptyAndExplicitlyEmptyConfigurationsNeverInvokeStarterOrWrite() async throws {
        let saved = try binding()
        for existing in [[saved], []] {
            let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
            prefs.bindings = existing
            var providerCalls = 0
            let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Loading must not select output") },
                                      preferences: prefs, registrar: registrar, initialBinding: {
                providerCalls += 1
                return saved
            })
            store.start()
            await store.drain()
            XCTAssertEqual(providerCalls, 0)
            XCTAssertEqual(prefs.saveAttempts, 0)
            XCTAssertEqual(store.bindings, existing)
            XCTAssertEqual(registrar.registered.count, existing.count)
            XCTAssertTrue(store.canEdit)
            store.stop()
        }
    }

    func testUnavailableStarterPersistsEmptyConfigurationAndDoesNotTryAgainOnRestart() async throws {
        let prefs = ShortcutTestPreferences()
        prefs.isMissing = true
        var providerCalls = 0
        for _ in 0..<2 {
            let registrar = ShortcutTestRegistrar()
            let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Setup must not select output") },
                                      preferences: prefs, registrar: registrar, initialBinding: {
                providerCalls += 1
                return nil
            })
            store.start()
            await store.drain()
            XCTAssertTrue(store.bindings.isEmpty)
            XCTAssertTrue(registrar.registered.isEmpty)
            XCTAssertTrue(store.canEdit)
            XCTAssertNil(store.recoveryTitle)
            store.stop()
        }
        XCTAssertFalse(prefs.isMissing)
        XCTAssertTrue(prefs.bindings.isEmpty)
        XCTAssertEqual(prefs.loads, 2)
        XCTAssertEqual(prefs.saveAttempts, 1)
        XCTAssertEqual(providerCalls, 1)
    }

    func testClearingStarterThenRestartingKeepsUserConfigurationEmpty() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.isMissing = true
        var providerCalls = 0
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Editing must not select output") },
                                  preferences: prefs, registrar: registrar, initialBinding: {
            providerCalls += 1
            return saved
        })
        store.updateDevices([device()])
        store.start()
        await store.drain()
        XCTAssertTrue(store.beginRecording(target: saved.target, deviceName: saved.lastKnownName))
        XCTAssertTrue(store.clearRecording())
        await store.drain()
        XCTAssertTrue(prefs.bindings.isEmpty)
        XCTAssertFalse(prefs.isMissing)
        store.stop()

        let restartedRegistrar = ShortcutTestRegistrar()
        let restarted = ShortcutStore(selectTarget: { _, _ in XCTFail("Restart must not select output") },
                                      preferences: prefs, registrar: restartedRegistrar, initialBinding: {
            providerCalls += 1
            return saved
        })
        restarted.updateDevices([device()])
        restarted.start()
        await restarted.drain()
        XCTAssertTrue(restarted.bindings.isEmpty)
        XCTAssertTrue(restartedRegistrar.registered.isEmpty)
        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(prefs.saveAttempts, 2, "Only initial setup and the explicit clear may write.")
        restarted.stop()
    }

    func testLoadFailureNeverFallsBackToStarterOrOverwritesConfiguration() async throws {
        let saved = try binding()
        for missing in [false, true] {
            let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
            prefs.bindings = [saved]
            prefs.isMissing = missing
            prefs.failLoad = true
            var providerCalls = 0
            let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Read failure must not select output") },
                                      preferences: prefs, registrar: registrar, initialBinding: {
                providerCalls += 1
                return saved
            })
            store.start()
            await store.drain()
            XCTAssertEqual(providerCalls, 0)
            XCTAssertEqual(prefs.saveAttempts, 0)
            XCTAssertEqual(prefs.bindings, [saved])
            XCTAssertEqual(prefs.isMissing, missing)
            XCTAssertEqual(registrar.registrationCalls, 0)
            XCTAssertFalse(store.canEdit)
            XCTAssertTrue(store.canRecover)
            XCTAssertEqual(store.recoveryTitle, expectedLocalized("Reload", "重新读取"))
            store.stop()
        }
    }

    func testStarterSaveFailureRequiresReloadBeforePublishingOrRegistering() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        prefs.isMissing = true
        prefs.failSave = true
        var providerCalls = 0
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Storage recovery must not select output") },
                                  preferences: prefs, registrar: registrar, initialBinding: {
            providerCalls += 1
            return saved
        })
        store.start()
        await store.drain()
        XCTAssertEqual(providerCalls, 1)
        XCTAssertTrue(prefs.isMissing)
        XCTAssertTrue(store.bindings.isEmpty)
        XCTAssertEqual(registrar.registrationCalls, 0)
        XCTAssertFalse(registrar.deliveryEnabled)
        XCTAssertFalse(store.canEdit)
        XCTAssertTrue(store.canRecover)
        XCTAssertEqual(store.recoveryTitle, expectedLocalized("Reload", "重新读取"))
        store.updateDevices([device()])
        await store.drain()
        XCTAssertEqual(prefs.saveAttempts, 1, "A directory update cannot silently retry a failed setup write.")
        prefs.failSave = false
        store.retryRecovery()
        await store.drain()
        XCTAssertEqual(prefs.loads, 2)
        XCTAssertEqual(providerCalls, 2)
        XCTAssertEqual(prefs.saveAttempts, 2)
        XCTAssertEqual(prefs.bindings, [saved])
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(registrar.registrationCalls, 1)
        XCTAssertTrue(registrar.deliveryEnabled)
        XCTAssertNil(store.recoveryTitle)
        store.stop()
    }

    func testStoppingDuringMissingFileReadDoesNotInvokeStarter() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let barrier = ShortcutIOBarrier()
        prefs.isMissing = true
        prefs.loadBarrier = barrier
        defer { barrier.release() }
        var providerCalls = 0
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Shutdown must not select output") },
                                  preferences: prefs, registrar: registrar, initialBinding: {
            providerCalls += 1
            return saved
        })
        store.start()
        await barrier.waitUntilEntered()
        store.stop()
        barrier.release()
        await store.drain()
        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(prefs.saveAttempts, 0)
        XCTAssertEqual(registrar.registrationCalls, 0)
        XCTAssertTrue(store.bindings.isEmpty)
    }

    func testStoppingDuringStarterLookupPreventsSaveAndLateRegistration() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let barrier = ShortcutIOBarrier()
        prefs.isMissing = true
        defer { barrier.release() }
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Shutdown must not select output") },
                                  preferences: prefs, registrar: registrar, initialBinding: {
            await barrier.wait()
            return saved
        })
        store.start()
        await barrier.waitUntilEntered()
        store.stop()
        var drained = false
        let waiting = Task { await store.drain(); drained = true }
        await Task.yield()
        XCTAssertFalse(drained)
        barrier.release()
        await waiting.value
        XCTAssertTrue(drained)
        XCTAssertEqual(prefs.saveAttempts, 0)
        XCTAssertTrue(prefs.isMissing)
        XCTAssertEqual(registrar.registrationCalls, 0)
        XCTAssertEqual(registrar.closes, 1)
        XCTAssertTrue(store.bindings.isEmpty)
        XCTAssertFalse(registrar.deliveryEnabled)
    }

    func testStoppingDrainsAcceptedStarterSaveOnEitherOutcomeWithoutLatePublication() async throws {
        for failSave in [false, true] {
            let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
            let barrier = ShortcutIOBarrier()
            prefs.isMissing = true
            prefs.failSave = failSave
            prefs.saveBarrier = barrier
            defer { barrier.release() }
            let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Shutdown must not select output") },
                                      preferences: prefs, registrar: registrar, initialBinding: { saved })
            store.start()
            await barrier.waitUntilEntered()
            store.stop()
            var drained = false
            let waiting = Task { await store.drain(); drained = true }
            waiting.cancel()
            await Task.yield()
            XCTAssertFalse(drained, "Cancellation cannot finish an accepted physical save.")
            XCTAssertEqual(prefs.saveAttempts, 1)
            barrier.release()
            await waiting.value
            XCTAssertTrue(drained)
            XCTAssertEqual(prefs.bindings, failSave ? [] : [saved])
            XCTAssertEqual(prefs.isMissing, failSave)
            XCTAssertTrue(store.bindings.isEmpty, "A closed Store cannot publish the late result.")
            XCTAssertEqual(registrar.registrationCalls, 0)
            XCTAssertEqual(registrar.closes, 1)
            XCTAssertFalse(registrar.deliveryEnabled)
            XCTAssertFalse(store.canRecover)
        }
    }

    func testStarterFinishingDuringQuitWaitsForCancellationBeforeRegistering() async throws {
        let saved = try binding(), prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
        let barrier = ShortcutIOBarrier()
        prefs.isMissing = true
        prefs.saveBarrier = barrier
        defer { barrier.release() }
        let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Quit preparation must not select output") },
                                  preferences: prefs, registrar: registrar, initialBinding: { saved })
        store.start()
        await barrier.waitUntilEntered()
        store.setSuspended(.quitting, true)
        barrier.release()
        await store.drain()
        XCTAssertEqual(prefs.bindings, [saved])
        XCTAssertEqual(store.bindings, [saved])
        XCTAssertEqual(registrar.registrationCalls, 0)
        XCTAssertFalse(registrar.deliveryEnabled)
        store.setSuspended(.quitting, false)
        XCTAssertEqual(registrar.registrationCalls, 1)
        XCTAssertTrue(registrar.deliveryEnabled)
        store.stop()
    }

    func testConflictingStarterIsRetainedVisibleAndCanBeReplaced() async throws {
        let saved = try binding()
        let replacement = try DeviceShortcut(keyCode: 19, modifiers: [.control, .shift])
        for systemConflict in [false, true] {
            let prefs = ShortcutTestPreferences(), registrar = ShortcutTestRegistrar()
            prefs.isMissing = true
            if systemConflict { registrar.system = [saved.shortcut] }
            else { registrar.refused = [saved.shortcut] }
            let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Resolving a conflict must not select output") },
                                      preferences: prefs, registrar: registrar, initialBinding: { saved })
            store.updateDevices([device()])
            store.start()
            await store.drain()
            XCTAssertEqual(store.binding(for: saved.target), saved)
            XCTAssertEqual(prefs.bindings, [saved])
            XCTAssertTrue(registrar.registered.isEmpty)
            XCTAssertNotNil(store.rowIssue(for: saved.target))
            XCTAssertEqual(store.recoveryTitle, expectedLocalized("Retry Registration", "重试注册"))
            XCTAssertTrue(store.canRecord(target: saved.target))
            XCTAssertTrue(store.beginRecording(target: saved.target, deviceName: saved.lastKnownName))
            XCTAssertTrue(store.commitRecording(replacement))
            await store.drain()
            XCTAssertEqual(store.bindings.count, 1)
            XCTAssertEqual(store.bindings.first?.target, saved.target)
            XCTAssertEqual(store.bindings.first?.shortcut, replacement)
            XCTAssertEqual(prefs.bindings, store.bindings)
            XCTAssertEqual(Set(registrar.registered.values), [replacement])
            XCTAssertNil(store.rowIssue(for: saved.target))
            XCTAssertNil(store.recoveryTitle)
            store.stop()
        }
    }

    func testVerifiedSpeakerProviderPreservesFullIdentityNameAndExactShortcutWithoutOtherAudioCalls() async throws {
        let uid = "BuiltinSpeaker:full-uid:42"
        let name = "Studio speaker %@ 中文 🎵"
        let hardware = FirstLaunchSpeakerHardware(result: .success(
            AudioDevice(id: "hal:\(uid)", name: name, transport: .speaker,
                        backend: .coreAudio(uid: uid))))
        let saved = try await FirstLaunchShortcut.builtInSpeaker(using: hardware)
        XCTAssertEqual(saved.target, .hal(uid: uid))
        XCTAssertEqual(saved.lastKnownName, name)
        XCTAssertEqual(saved.shortcut.keyCode, 18)
        XCTAssertEqual(saved.shortcut.modifiers, [.control, .shift])
        let reads = await hardware.speakerReads
        XCTAssertEqual(reads, 1)
    }

    func testSpeakerProviderRejectsInconsistentNonHALUnavailableAndEmptyIdentity() async {
        let candidates = [
            AudioDevice(id: "hal:other-uid", name: "Mac mini Speakers", transport: .speaker,
                        backend: .coreAudio(uid: speakerUID)),
            AudioDevice(id: "route:receiver", name: "Mac mini Speakers", transport: .speaker,
                        backend: .privateRoute(identifier: "receiver")),
            AudioDevice(id: "hal:\(speakerUID)", name: "Mac mini Speakers", transport: .speaker,
                        backend: .coreAudio(uid: speakerUID), isAvailable: false),
            AudioDevice(id: "hal:  ", name: "Mac mini Speakers", transport: .speaker,
                        backend: .coreAudio(uid: "  "))
        ]
        for candidate in candidates {
            let hardware = FirstLaunchSpeakerHardware(result: .success(candidate))
            do {
                _ = try await FirstLaunchShortcut.builtInSpeaker(using: hardware)
                XCTFail("A display name must not repair missing or inconsistent speaker identity.")
            } catch {
                guard case AudioServiceError.ambiguousIdentity = error else {
                    XCTFail("Expected identity rejection, got \(error)")
                    continue
                }
            }
            let reads = await hardware.speakerReads
            XCTAssertEqual(reads, 1)
        }
    }

    func testSpeakerVerificationFailurePropagatesWithoutGuessingFromCurrentOutput() async {
        let hardware = FirstLaunchSpeakerHardware(result: .failure(.unavailable))
        do {
            _ = try await FirstLaunchShortcut.builtInSpeaker(using: hardware)
            XCTFail("Failed verification must not fall back to the current output or a name match.")
        } catch {
            XCTAssertEqual(error as? FirstLaunchSpeakerFailure, .unavailable)
        }
        let reads = await hardware.speakerReads
        XCTAssertEqual(reads, 1)
    }
}

private enum FirstLaunchSpeakerFailure: Error, Equatable { case unavailable }

private actor FirstLaunchSpeakerHardware: AudioHardwareProviding {
    private let result: Result<AudioDevice, FirstLaunchSpeakerFailure>
    private(set) var speakerReads = 0

    init(result: Result<AudioDevice, FirstLaunchSpeakerFailure>) { self.result = result }

    func builtInSpeaker() async throws -> AudioDevice {
        speakerReads += 1
        return try result.get()
    }

    nonisolated func beginShutdown() { XCTFail("Starter lookup must not shut down audio.") }
    func snapshot() async throws -> CoreAudioSnapshot {
        XCTFail("Starter lookup must use verified speakers, not infer from the current output.")
        throw FirstLaunchSpeakerFailure.unavailable
    }
    func select(uid: String) async throws {
        XCTFail("Starter lookup must not select output.")
        throw FirstLaunchSpeakerFailure.unavailable
    }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {
        XCTFail("Starter lookup must not create an audio observer.")
    }
    func stopObserving() async { XCTFail("Starter lookup must not stop audio observers.") }
}
