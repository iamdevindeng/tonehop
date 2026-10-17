import AppKit
import XCTest
@testable import ToneHop

@MainActor
final class DeviceRecordIntegrationTests: XCTestCase {
    func testCatalogPresenceReachesShortcutStoreAndReappearanceRejectsOpenRemoval() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.shortcuts.drain()
        XCTAssertTrue(fixture.shortcuts.offlineBindings.isEmpty)
        XCTAssertEqual(fixture.shortcuts.confirmingBindings.count, 1)

        fixture.audio.refresh()
        await waitUntil { fixture.shortcuts.offlineBindings.count == 1 }
        let modal = ShortcutIOBarrier()
        fixture.coordinator.presentRecordRemoval = { _ in
            await modal.wait()
            return true
        }
        fixture.coordinator.removeRecord(fixture.saved)
        await modal.waitUntilEntered()

        await fixture.hardware.showDevice()
        fixture.audio.refresh()
        await waitUntil { fixture.shortcuts.devices.count == 1 }
        XCTAssertTrue(fixture.shortcuts.offlineBindings.isEmpty)
        modal.release()
        await waitUntil { fixture.shortcuts.canEdit }
        await fixture.shortcuts.drain()
        XCTAssertEqual(fixture.preferences.bindings, [fixture.saved])
        XCTAssertEqual(fixture.preferences.saves, 0)
        XCTAssertEqual(fixture.registrar.registered.count, 1)
        try await fixture.audio.shutdown()
    }

    func testRecordingClearNeverPresentsRemovalOrSelectsAudio() async throws {
        let fixture = try Fixture()
        await fixture.hardware.showDevice()
        fixture.coordinator.presentRecordRemoval = { _ in
            XCTFail("Backspace clearing must never present a record-removal alert")
            return false
        }
        fixture.coordinator.start()
        fixture.audio.refresh()
        await waitUntil { fixture.shortcuts.devices.count == 1 && fixture.shortcuts.canEdit }
        XCTAssertTrue(fixture.shortcuts.beginRecording(target: fixture.saved.target, deviceName: "Test USB"))
        XCTAssertTrue(fixture.shortcuts.clearRecording())
        await fixture.shortcuts.drain()
        XCTAssertTrue(fixture.preferences.bindings.isEmpty)
        XCTAssertTrue(fixture.registrar.registered.isEmpty)
        XCTAssertEqual(fixture.audio.devices.count, 1, "Clearing a binding cannot remove a discovered device")
        try await fixture.audio.shutdown()
    }

    func testRecordRemovalConfirmationAndCancellationUseCurrentLocalRecord() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        fixture.audio.refresh()
        await waitUntil { fixture.shortcuts.offlineBindings.count == 1 && fixture.shortcuts.canEdit }
        let cancelled = expectation(description: "record-removal cancellation")
        fixture.coordinator.presentRecordRemoval = { request in
            XCTAssertEqual(request.deviceName, "Test USB")
            cancelled.fulfill()
            return false
        }
        fixture.coordinator.removeRecord(fixture.saved)
        await fulfillment(of: [cancelled], timeout: 2)
        await waitUntil { fixture.shortcuts.canEdit }
        XCTAssertEqual(fixture.preferences.bindings, [fixture.saved])

        fixture.coordinator.presentRecordRemoval = { _ in true }
        fixture.coordinator.removeRecord(fixture.saved)
        await waitUntil { fixture.shortcuts.bindings.isEmpty }
        await fixture.shortcuts.drain()
        XCTAssertTrue(fixture.shortcuts.offlineBindings.isEmpty)
        XCTAssertTrue(fixture.preferences.bindings.isEmpty)
        XCTAssertTrue(fixture.registrar.registered.isEmpty)
        try await fixture.audio.shutdown()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Expected observable state did not arrive")
    }

    @MainActor private final class Fixture {
        let saved: ShortcutBinding
        let hardware = RecordTestHardware()
        let audio: AudioStore
        let shortcuts: ShortcutStore
        let preferences = ShortcutTestPreferences()
        let registrar = ShortcutTestRegistrar()
        let coordinator: AudioInteractionCoordinator

        init() throws {
            saved = ShortcutBinding(target: .hal(uid: "record-test-usb"),
                                    shortcut: try DeviceShortcut(keyCode: 18, modifiers: [.command, .control]),
                                    lastKnownName: "Test USB")
            preferences.bindings = [saved]
            audio = AudioStore(hardware: hardware, routes: RecordTestRoutes())
            shortcuts = ShortcutStore(selectTarget: { _, _ in XCTFail("Record editing must not select audio") },
                                      preferences: preferences, registrar: registrar)
            let volume = AudioVolumeStore(provider: RecordTestVolume(), resolveTarget: { _ in
                throw AudioVolumeIssue.identityUnconfirmed
            })
            coordinator = AudioInteractionCoordinator(audio: audio, shortcuts: shortcuts, volume: volume)
        }
    }
}

private actor RecordTestHardware: AudioHardwareProviding {
    private var visible = false
    func showDevice() { visible = true }
    nonisolated func beginShutdown() {}
    func snapshot() async throws -> CoreAudioSnapshot {
        let uid = "record-test-usb"
        return CoreAudioSnapshot(devices: visible ? [AudioDevice(id: "hal:\(uid)", name: "Test USB",
            transport: .usb, backend: .coreAudio(uid: uid), shortcutTarget: .hal(uid: uid))] : [],
            currentDeviceID: nil, systemSoundDeviceID: nil, warnings: [],
            discovery: .init(observedIdentifiers: visible ? [uid] : [], isComplete: true))
    }
    func select(uid: String) async throws { XCTFail("No audio writes allowed") }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {}
    func stopObserving() async {}
}

@MainActor
private final class RecordTestRoutes: PrivateRouting {
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
    func beginShutdown() {}
    func snapshot() -> PrivateRouteSnapshot { .init(routes: [], warning: nil, diagnostics: "record fixture") }
    func select(identifier: String) async throws { XCTFail("No private route writes allowed") }
    func prepareToLeave() async throws { XCTFail("No route lifecycle changes allowed") }
    func completedLeave() async throws { XCTFail("No route lifecycle changes allowed") }
}

private struct RecordTestVolume: AudioVolumeProviding {
    func readVolume(for target: AudioVolumeTarget) async throws -> AudioVolumeSnapshot {
        throw AudioVolumeIssue.identityUnconfirmed
    }
    func setVolume(_ value: Float, for target: AudioVolumeTarget, permit: AudioMutationPermit) async throws -> AudioVolumeWriteResult {
        XCTFail("No volume writes allowed")
        throw AudioVolumeIssue.identityUnconfirmed
    }
    func observeVolumeChanges(targets: [AudioVolumeTarget], changed: @escaping @Sendable () -> Void) async throws {}
    func stopObservingVolume() async {}
}
