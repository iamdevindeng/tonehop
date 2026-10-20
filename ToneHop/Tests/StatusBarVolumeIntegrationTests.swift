import AppKit
import XCTest
@testable import ToneHop

/// Uses the normal Store/coordinator/controller graph with every system seam
/// injected. Provider callbacks exercise the menu bar while its panel is closed.
@MainActor
final class StatusBarVolumeIntegrationTests: XCTestCase {
    func testProviderNotificationsUpdateClosedPanelStatusWithoutChangingItsWidthOrAudio() async throws {
        let fixture = StatusVolumeFixture()
        defer { fixture.stop() }
        let button = try XCTUnwrap(fixture.item.button)
        let visiblePanels = Set(NSApp.windows.filter { $0 is NSPanel && $0.isVisible }.map(ObjectIdentifier.init))
        await start(fixture, button: button)
        let originalImage = try XCTUnwrap(button.image)
        let imageSize = originalImage.size
        let itemLength = fixture.item.length
        let initialPixels = try XCTUnwrap(originalImage.tiffRepresentation)
        XCTAssertTrue(originalImage.isTemplate)
        XCTAssertEqual(button.toolTip, "Test speaker\n" + volumeHelp(35))
        XCTAssertEqual(button.accessibilityLabel(), expectedLocalized("ToneHop, Test speaker", "ToneHop，Test speaker"))

        for percentage in [9, 10, 100, 0] {
            fixture.provider.readings[StatusVolumeHardware.speakerUID] = .init(value: Float(percentage) / 100)
            fixture.provider.signalChange()
            await waitUntil("notification publishes the confirmed \(percentage)% value without opening") {
                button.accessibilityValue() as? String == self.volumeHelp(percentage)
            }
            XCTAssertEqual(button.image?.size, imageSize)
            XCTAssertEqual(fixture.item.length, itemLength)
            XCTAssertTrue(button.image?.isTemplate == true)
        }
        XCTAssertNotEqual(button.image?.tiffRepresentation, initialPixels,
                          "The visible image, as well as accessibility, must reflect changed volume.")

        fixture.provider.readings[StatusVolumeHardware.speakerUID] = .init(value: 0.65, mute: .muted)
        fixture.provider.signalChange()
        let mutedHelp = expectedLocalized("Muted; volume setting 65%", "已静音；设定音量 65%")
        await waitUntil("confirmed mute reaches the native status button") {
            button.accessibilityValue() as? String == mutedHelp
        }
        let mutedPixels = try XCTUnwrap(button.image?.tiffRepresentation)
        XCTAssertEqual(button.image?.size, imageSize)
        XCTAssertEqual(fixture.item.length, itemLength)
        XCTAssertEqual(button.toolTip, "Test speaker\n" + mutedHelp)

        fixture.provider.readings[StatusVolumeHardware.speakerUID] =
            .init(value: nil, mute: .unsupported, capability: .unavailable(.unsupported))
        fixture.provider.signalChange()
        let unsupportedHelp = expectedLocalized(
            "This device does not provide a system volume value\nMute status is unavailable",
            "此设备不提供系统音量值\n无法读取静音状态")
        await waitUntil("unsupported volume exposes its explanation") {
            button.accessibilityValue() as? String == unsupportedHelp
        }
        XCTAssertNotEqual(button.image?.tiffRepresentation, mutedPixels,
                          "Unavailable volume and confirmed mute need distinct visible states.")
        XCTAssertEqual(button.image?.size, imageSize)
        XCTAssertEqual(fixture.item.length, itemLength)
        XCTAssertEqual(Set(NSApp.windows.filter { $0 is NSPanel && $0.isVisible }.map(ObjectIdentifier.init)), visiblePanels)
        assertReadOnly(fixture)
        try await fixture.shutdown()
    }

    func testExternalOutputChangeDoesNotBorrowPreviousDevicesVolumeWhileNewReadIsPending() async throws {
        let fixture = StatusVolumeFixture()
        defer { fixture.stop() }
        let button = try XCTUnwrap(fixture.item.button)
        await start(fixture, button: button)
        let originalSize = button.image?.size
        fixture.provider.heldUIDs = [StatusVolumeHardware.speakerUID, StatusVolumeHardware.headphonesUID]
        fixture.provider.signalChange()
        await waitUntil("old output read is in flight") {
            fixture.provider.hasPendingRead(for: StatusVolumeHardware.speakerUID)
        }

        fixture.hardware.includeHeadphones = true
        fixture.hardware.currentUID = StatusVolumeHardware.headphonesUID
        fixture.hardware.signalChange()
        let readingHelp = expectedLocalized("Reading volume…", "正在读取音量…")
        await waitUntil("the new output has no confirmed volume yet") {
            fixture.audio.currentDeviceID == "hal:\(StatusVolumeHardware.headphonesUID)"
                && fixture.provider.hasPendingRead(for: StatusVolumeHardware.headphonesUID)
                && button.toolTip == "Test headphones\n" + readingHelp
        }
        XCTAssertEqual(button.accessibilityValue() as? String, readingHelp)
        XCTAssertEqual(button.image?.size, originalSize)

        fixture.provider.releaseRead(for: StatusVolumeHardware.speakerUID, reading: .init(value: 0.95))
        await waitUntil("the previous device's late read completes") {
            fixture.volume.state(for: "hal:\(StatusVolumeHardware.speakerUID)")?.snapshot?.value == 0.95
        }
        XCTAssertEqual(button.toolTip, "Test headphones\n" + readingHelp,
                       "A late read for another device must not replace the current output's unavailable state.")
        fixture.provider.releaseRead(for: StatusVolumeHardware.headphonesUID, reading: .init(value: 0.8))
        await waitUntil("the current device's own read publishes 80%") {
            button.toolTip == "Test headphones\n" + self.volumeHelp(80)
        }
        XCTAssertEqual(button.image?.size, originalSize)
        assertReadOnly(fixture)
        try await fixture.shutdown()
    }

    func testQuitPauseAndCancellationRequireFreshVolumeBeforeRestoringPercentage() async throws {
        let fixture = StatusVolumeFixture()
        defer { fixture.stop() }
        let button = try XCTUnwrap(fixture.item.button)
        await start(fixture, button: button)
        let imageSize = button.image?.size
        fixture.audio.beginQuitPreparation()
        let confirmingHelp = expectedLocalized("Confirming volume…", "正在确认音量…")
        await waitUntil("quit preparation hides cached volume") {
            fixture.volume.isPaused && button.accessibilityValue() as? String == confirmingHelp
        }
        let plan = try await fixture.audio.prepareToQuit()
        XCTAssertFalse(plan.requiresConfirmation, "The injected fixture owns no audio stream to clean up.")
        let readCount = fixture.provider.readTargets.count
        fixture.provider.readings[StatusVolumeHardware.speakerUID] = .init(value: 0.72)
        fixture.provider.signalChange()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.provider.readTargets.count, readCount)
        XCTAssertEqual(button.accessibilityValue() as? String, confirmingHelp)

        fixture.provider.heldUIDs = [StatusVolumeHardware.speakerUID]
        fixture.audio.cancelQuit()
        let readingHelp = expectedLocalized("Reading volume…", "正在读取音量…")
        await waitUntil("cancelling quit waits for a fresh read") {
            !fixture.volume.isPaused && fixture.provider.hasPendingRead(for: StatusVolumeHardware.speakerUID)
                && button.accessibilityValue() as? String == readingHelp
        }
        XCTAssertNil(fixture.volume.state(for: "hal:\(StatusVolumeHardware.speakerUID)")?.snapshot)
        fixture.provider.releaseRead(for: StatusVolumeHardware.speakerUID, reading: .init(value: 0.72))
        await waitUntil("fresh volume replaces the unavailable state") {
            button.accessibilityValue() as? String == self.volumeHelp(72)
        }
        XCTAssertEqual(button.image?.size, imageSize)
        assertReadOnly(fixture)
        try await fixture.shutdown()
    }

    func testStoppedControllerIgnoresLateReadAndClosedStoreIgnoresSavedProviderCallback() async throws {
        let fixture = StatusVolumeFixture()
        defer { fixture.stop() }
        let button = try XCTUnwrap(fixture.item.button)
        await start(fixture, button: button)
        let callback = try XCTUnwrap(fixture.provider.onChange)
        fixture.provider.heldUIDs = [StatusVolumeHardware.speakerUID]
        fixture.provider.signalChange()
        await waitUntil("a volume read is pending when presentation stops") {
            fixture.provider.hasPendingRead(for: StatusVolumeHardware.speakerUID)
        }
        fixture.controller.stop()
        let stoppedHelp = button.accessibilityValue() as? String
        let stoppedTooltip = button.toolTip
        let stoppedPixels = button.image?.tiffRepresentation
        fixture.provider.releaseRead(for: StatusVolumeHardware.speakerUID, reading: .init(value: 0.91))
        await fixture.volume.drain()
        await Task.yield()
        XCTAssertEqual(fixture.volume.state(for: "hal:\(StatusVolumeHardware.speakerUID)")?.snapshot?.value, 0.91)
        XCTAssertEqual(button.accessibilityValue() as? String, stoppedHelp)
        XCTAssertEqual(button.toolTip, stoppedTooltip)
        XCTAssertEqual(button.image?.tiffRepresentation, stoppedPixels,
                       "A controller that has stopped must not redraw after an already-started read returns.")

        try await fixture.shutdown()
        XCTAssertTrue(fixture.volume.isClosed)
        XCTAssertGreaterThan(fixture.provider.stopObservationCount, 0)
        let readCount = fixture.provider.readTargets.count
        callback()
        try await Task.sleep(for: .milliseconds(30))
        await fixture.volume.drain()
        XCTAssertEqual(fixture.provider.readTargets.count, readCount)
        XCTAssertEqual(button.accessibilityValue() as? String, stoppedHelp)
        assertReadOnly(fixture)
    }

    private func start(_ fixture: StatusVolumeFixture, button: NSStatusBarButton) async {
        fixture.interactions.start()
        fixture.audio.start()
        await waitUntil("normal store/coordinator startup publishes current volume and installs listeners") {
            button.accessibilityValue() as? String == self.volumeHelp(35)
                && fixture.provider.onChange != nil && fixture.hardware.onChange != nil
        }
    }

    private func volumeHelp(_ percent: Int) -> String {
        expectedLocalized("Volume \(percent)%", "音量 \(percent)%")
    }

    private func assertReadOnly(_ fixture: StatusVolumeFixture,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.provider.readTargets.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.hardware.selectedUIDs.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.routes.mutations.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.provider.writeTargets.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.provider.resolvedDeviceIDs.isEmpty,
                      "Displaying volume must not enter the volume write resolver.", file: file, line: line)
    }

    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), description, file: file, line: line)
    }
}

@MainActor
private final class StatusVolumeFixture {
    let hardware: StatusVolumeHardware
    let routes: StatusVolumeRoutes
    let provider: StatusVolumeProvider
    let audio: AudioStore
    let volume: AudioVolumeStore
    let interactions: AudioInteractionCoordinator
    let item: NSStatusItem
    let controller: StatusBarController

    init() {
        let hardware = StatusVolumeHardware()
        let routes = StatusVolumeRoutes()
        let provider = StatusVolumeProvider()
        let audio = AudioStore(hardware: hardware, routes: routes, pollingInterval: .seconds(3_600))
        self.hardware = hardware
        self.routes = routes
        self.provider = provider
        self.audio = audio
        let volume = AudioVolumeStore(provider: provider, resolveTarget: { [weak audio] deviceID in
            provider.resolvedDeviceIDs.append(deviceID)
            guard let audio else { throw CancellationError() }
            return try await audio.resolveVolumeTarget(deviceID: deviceID)
        }, pollingInterval: .seconds(3_600))
        self.volume = volume
        let shortcuts = ShortcutStore(selectTarget: { [weak audio] target, request in
            audio?.select(target: target, request: request)
        }, preferences: StatusVolumePreferences(), registrar: StatusVolumeRegistrar(), menuConflict: { _ in nil })
        let interactions = AudioInteractionCoordinator(audio: audio, shortcuts: shortcuts, volume: volume)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.interactions = interactions
        self.item = item
        controller = StatusBarController(store: audio, interactions: interactions, statusItem: item)
    }

    func stop() {
        controller.stop()
        provider.releaseAllReads()
        audio.stop()
    }

    func shutdown() async throws {
        controller.stop()
        provider.releaseAllReads()
        try await audio.shutdown()
    }
}

@MainActor
private final class StatusVolumeHardware: AudioHardwareProviding {
    static let speakerUID = "status-volume-speaker"
    static let headphonesUID = "status-volume-headphones"
    var currentUID: String? = speakerUID
    var includeHeadphones = false
    private(set) var selectedUIDs: [String] = []
    private(set) var onChange: (@Sendable () -> Void)?

    nonisolated func beginShutdown() {}

    func snapshot() async throws -> CoreAudioSnapshot {
        var devices = [AudioDevice(id: "hal:\(Self.speakerUID)", name: "Test speaker", transport: .speaker,
            backend: .coreAudio(uid: Self.speakerUID), icon: .systemSymbol("macmini.fill"))]
        var objects: [String: UInt32] = [Self.speakerUID: 1]
        if includeHeadphones {
            devices.append(AudioDevice(id: "hal:\(Self.headphonesUID)", name: "Test headphones", transport: .bluetooth,
                backend: .coreAudio(uid: Self.headphonesUID), icon: .systemSymbol("headphones")))
            objects[Self.headphonesUID] = 2
        }
        return CoreAudioSnapshot(devices: devices, currentDeviceID: currentUID.map { "hal:\($0)" },
            systemSoundDeviceID: "hal:\(Self.speakerUID)", warnings: [], confirmedDeviceObjects: objects)
    }

    func select(uid: String) async throws {
        selectedUIDs.append(uid)
        XCTFail("Menu bar presentation must never select an audio output.")
    }

    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws { onChange = changed }
    func stopObserving() async { onChange = nil }
    func signalChange() { onChange?() }
}

@MainActor
private final class StatusVolumeRoutes: PrivateRouting {
    var onChange: (() -> Void)?
    private(set) var mutations: [String] = []
    func start() {}
    func stop() { onChange = nil }
    func beginShutdown() {}
    func snapshot() -> PrivateRouteSnapshot { .init(routes: [], warning: nil, diagnostics: "status volume test") }
    func select(identifier: String) async throws { mutations.append("select:\(identifier)") }
    func prepareToLeave() async throws { mutations.append("prepareToLeave") }
    func completedLeave() async throws { mutations.append("completedLeave") }
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? { nil }
}

@MainActor
private final class StatusVolumeProvider: AudioVolumeProviding {
    struct Reading {
        var value: Float?
        var mute: AudioVolumeMuteState = .unmuted
        var capability: AudioVolumeCapability = .writable(.main)

        func snapshot(for target: AudioVolumeTarget) -> AudioVolumeSnapshot {
            AudioVolumeSnapshot(target: target, value: value, capability: capability, mute: mute)
        }
    }

    var readings: [String: Reading] = [StatusVolumeHardware.speakerUID: .init(value: 0.35)]
    var heldUIDs = Set<String>()
    var resolvedDeviceIDs: [String] = []
    private(set) var readTargets: [AudioVolumeTarget] = []
    private(set) var writeTargets: [AudioVolumeTarget] = []
    private(set) var onChange: (@Sendable () -> Void)?
    private(set) var stopObservationCount = 0
    private var pending: [String: (AudioVolumeTarget, CheckedContinuation<AudioVolumeSnapshot, any Error>)] = [:]

    func readVolume(for target: AudioVolumeTarget) async throws -> AudioVolumeSnapshot {
        readTargets.append(target)
        if heldUIDs.contains(target.uid) {
            return try await withCheckedThrowingContinuation { pending[target.uid] = (target, $0) }
        }
        guard let reading = readings[target.uid] else { throw AudioVolumeIssue.identityUnconfirmed }
        return reading.snapshot(for: target)
    }

    func setVolume(_ value: Float, for target: AudioVolumeTarget,
                   permit: AudioMutationPermit) async throws -> AudioVolumeWriteResult {
        writeTargets.append(target)
        XCTFail("Menu bar presentation must never write system volume.")
        throw AudioVolumeIssue.unsupported
    }

    func observeVolumeChanges(targets: [AudioVolumeTarget], changed: @escaping @Sendable () -> Void) async throws {
        onChange = changed
    }

    func stopObservingVolume() async {
        stopObservationCount += 1
        onChange = nil
    }

    func signalChange() { onChange?() }
    func hasPendingRead(for uid: String) -> Bool { pending[uid] != nil }

    func releaseRead(for uid: String, reading: Reading) {
        heldUIDs.remove(uid)
        readings[uid] = reading
        guard let (target, continuation) = pending.removeValue(forKey: uid) else { return }
        continuation.resume(returning: reading.snapshot(for: target))
    }

    func releaseAllReads() {
        heldUIDs.removeAll()
        let continuations = pending.values.map(\.1)
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private actor StatusVolumePreferences: ShortcutPreferencesProviding {
    func load() async throws -> [ShortcutBinding]? { [] }
    func save(_ bindings: [ShortcutBinding]) async throws {
        XCTFail("Menu bar presentation must never save shortcut preferences.")
    }
}

@MainActor
private final class StatusVolumeRegistrar: GlobalShortcutRegistering {
    var onPress: ((GlobalShortcutRegistration) -> Void)?
    func register(_ shortcut: DeviceShortcut) throws -> GlobalShortcutRegistration {
        XCTFail("No shortcut is configured in the menu bar volume fixture.")
        return GlobalShortcutRegistration()
    }
    func unregister(_ registration: GlobalShortcutRegistration) throws {}
    func systemShortcuts() throws -> Set<DeviceShortcut> { [] }
    func retryFailedCleanup(for shortcut: DeviceShortcut?) throws {}
    func setDeliveryEnabled(_ enabled: Bool) {}
    func close() throws { onPress = nil }
}
