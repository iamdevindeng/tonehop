import CoreAudio
import Foundation
import XCTest
@testable import ToneHop

@MainActor
final class CoreAudioDirectoryListenerTests: XCTestCase {
    func testResetClosesOldGenerationCallbacksAndRebuildsDirectoryAndVolumeListeners() async throws {
        let runtime = DirectoryListenerTestRuntime()
        let io = DirectoryListenerVolumeIO(runtime: runtime)
        let service = CoreAudioService(volumeIO: io, makeDirectoryListener: runtime.factory)
        let epoch = try XCTUnwrap(service.serviceEpoch)
        let old = epoch.capture()
        let resets = DirectoryListenerCounter()
        let changes = DirectoryListenerCounter()
        let volume = DirectoryListenerCounter()
        try await service.observeEvents { event in
            switch event {
            case .changed: changes.increment()
            case .serviceRestarted: resets.increment()
            }
        }
        let target = AudioVolumeTarget(deviceID: "hal:volume-listener-fixture", uid: "volume-listener-fixture", serviceGeneration: old.id)
        try await service.observeVolumeChanges(targets: [target]) { volume.increment() }
        runtime.fire(4)
        XCTAssertEqual(volume.count, 1)
        runtime.fire(3)
        let replacement = epoch.capture()
        XCTAssertNotEqual(old.id, replacement.id)
        runtime.fire(3)
        runtime.fire(0)
        runtime.fire(4)
        XCTAssertEqual(resets.count, 1)
        XCTAssertEqual(changes.count, 0)
        XCTAssertEqual(volume.count, 1)

        try await service.observeEvents { _ in changes.increment() }
        let nextTarget = AudioVolumeTarget(deviceID: target.deviceID, uid: target.uid, serviceGeneration: replacement.id)
        try await service.observeVolumeChanges(targets: [nextTarget]) { volume.increment() }
        XCTAssertEqual(runtime.addedIDs, Array(0...9))
        XCTAssertTrue(runtime.removedIDs.isEmpty, "Reset already retired remote old-generation listeners; do not Remove against reused IDs.")
        runtime.fire(5)
        runtime.fire(9)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(volume.count, 2)
        runtime.fire(3)
        XCTAssertEqual(epoch.capture().id, replacement.id)
        service.beginShutdown()
        runtime.fire(8)
        XCTAssertEqual(epoch.capture().id, replacement.id, "Shutdown must reject even a current reset callback.")
        await service.stopObserving()
        await service.stopObservingVolume()
        XCTAssertEqual(io.mutationAttempts, 0)
    }

    func testResetDuringListenerRegistrationRemovesAmbiguousLateRegistrationAndCanRetry() async throws {
        let runtime = DirectoryListenerTestRuntime()
        runtime.fireDuringAdd(id: 3)
        let service = CoreAudioService(volumeIO: DirectoryListenerVolumeIO(runtime: runtime), makeDirectoryListener: runtime.factory)
        let resets = DirectoryListenerCounter()
        do {
            try await service.observeEvents { _ in resets.increment() }
            XCTFail("An installation spanning service generations cannot report success.")
        } catch is AudioServiceResetError { }
        XCTAssertEqual(resets.count, 1)
        XCTAssertEqual(runtime.removedIDs, [3], "The Add that returned across reset may exist in the new service and needs its exact Remove.")
        let changes = DirectoryListenerCounter()
        try await service.observeEvents { _ in changes.increment() }
        runtime.fire(0)
        runtime.fire(3)
        XCTAssertEqual(changes.count, 0)
        runtime.fire(4)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(runtime.addedIDs, Array(0...7))
        await service.stopObserving()
    }

    func testStoppedResetCallbackCannotChangeServiceGeneration() async throws {
        let runtime = DirectoryListenerTestRuntime()
        let service = CoreAudioService(volumeIO: DirectoryListenerVolumeIO(runtime: runtime), makeDirectoryListener: runtime.factory)
        try await service.observeChanges {}
        let generation = service.serviceEpoch?.capture().id
        await service.stopObserving()
        runtime.fire(3)
        XCTAssertEqual(service.serviceEpoch?.capture().id, generation)
    }

    func testDirectoryObservationIncludesAudioServiceRestartNotification() async throws {
        let runtime = DirectoryListenerTestRuntime()
        let service = CoreAudioService(volumeIO: DirectoryListenerVolumeIO(runtime: runtime),
                                       makeDirectoryListener: runtime.factory)
        let changes = DirectoryListenerCounter()
        try await service.observeChanges { changes.increment() }

        let ids = runtime.addedIDs
        let selectors = runtime.selectors(for: ids)
        XCTAssertEqual(selectors.filter { $0 == kAudioHardwarePropertyServiceRestarted }.count, 1,
                       "A successful initial observation must include HAL service reset so its lost listeners can be rebuilt.")
        XCTAssertTrue(runtime.areSystemGlobalMain(ids))
        if let index = selectors.firstIndex(of: kAudioHardwarePropertyServiceRestarted) {
            runtime.fire(ids[index])
            XCTAssertEqual(changes.count, 1)
        }
        await service.stopObserving()
    }

    func testDirectoryRebuildLeavesVolumeRegistrationAndCallbackActive() async throws {
        let runtime = DirectoryListenerTestRuntime()
        let volumeIO = DirectoryListenerVolumeIO(runtime: runtime)
        let service = CoreAudioService(volumeIO: volumeIO, makeDirectoryListener: runtime.factory)
        let volume = DirectoryListenerCounter()
        let oldDirectory = DirectoryListenerCounter()
        let newDirectory = DirectoryListenerCounter()
        let target = AudioVolumeTarget(deviceID: "hal:volume-listener-fixture", uid: "volume-listener-fixture")
        try await service.observeVolumeChanges(targets: [target]) { volume.increment() }
        XCTAssertEqual(runtime.addedIDs, [0])
        try await service.observeChanges { oldDirectory.increment() }
        XCTAssertEqual(runtime.addedIDs, [0, 1, 2, 3, 4])
        XCTAssertEqual(runtime.selectors(for: [1, 2, 3]), [kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice])
        XCTAssertTrue(runtime.areSystemGlobalMain([1, 2, 3]))
        runtime.fire(0)
        [1, 2, 3].forEach { runtime.fire($0) }
        XCTAssertEqual(volume.count, 1)
        XCTAssertEqual(oldDirectory.count, 3)

        try await service.observeChanges { newDirectory.increment() }

        XCTAssertEqual(runtime.removedIDs, [1, 2, 3, 4])
        XCTAssertEqual(runtime.addedIDs, Array(0...8))
        [1, 2, 3].forEach { runtime.fire($0) }
        XCTAssertEqual(oldDirectory.count, 3)
        [5, 6, 7].forEach { runtime.fire($0) }
        XCTAssertEqual(newDirectory.count, 3)
        runtime.fire(0)
        XCTAssertEqual(volume.count, 2, "Directory rebuilding must leave the installed volume callback live.")
        await service.stopObserving()
        XCTAssertEqual(runtime.removedIDs, Array(1...8))
        runtime.fire(0)
        XCTAssertEqual(volume.count, 3, "Stopping directory observers must not stop volume observers.")
        await service.stopObservingVolume()
        XCTAssertEqual(runtime.removedIDs.last, 0)
        runtime.fire(0)
        XCTAssertEqual(volume.count, 3)
        XCTAssertTrue(runtime.argumentMatches.allSatisfy { $0 })
        XCTAssertEqual(volumeIO.mutationAttempts, 0)
    }

    func testPartialInstallFailureClosesEntireBatchBeforeRemovingAnyRegistration() async throws {
        let runtime = DirectoryListenerTestRuntime()
        runtime.failAdd(id: 2, status: -911)
        // The first native Remove invokes another callback from the failed
        // batch. All deliveries must already be closed before Remove starts.
        runtime.fireDuringNextRemove(id: 1)
        let service = CoreAudioService(volumeIO: DirectoryListenerVolumeIO(runtime: runtime),
                                       makeDirectoryListener: runtime.factory)
        let failedBatch = DirectoryListenerCounter()
        do {
            try await service.observeChanges { failedBatch.increment() }
            XCTFail("A partial install must report the failing native registration.")
        } catch {
            guard case let AudioServiceError.system(_, status) = error else {
                return XCTFail("Unexpected registration error: \(error)")
            }
            XCTAssertEqual(status, -911)
        }
        XCTAssertEqual(runtime.addedIDs, [0, 1, 2])
        XCTAssertEqual(runtime.removedIDs, [0, 1], "Only successful registrations require removal.")
        XCTAssertEqual(failedBatch.count, 0, "Even a sibling callback fired synchronously by Remove must be closed.")
        [0, 1, 2].forEach { runtime.fire($0) }
        XCTAssertEqual(failedBatch.count, 0, "The failed Add's callback must also be closed.")

        let replacement = DirectoryListenerCounter()
        try await service.observeChanges { replacement.increment() }
        XCTAssertEqual(runtime.addedIDs, Array(0...6))
        XCTAssertEqual(runtime.removedIDs, [0, 1])
        [3, 4, 5].forEach { runtime.fire($0) }
        XCTAssertEqual(replacement.count, 3)
        XCTAssertTrue(runtime.argumentMatches.allSatisfy { $0 })
        await service.stopObserving()
    }

    func testFailedRemovalRetainsOriginalTokenAndBlocksReplacementUntilRetrySucceeds() async throws {
        let runtime = DirectoryListenerTestRuntime()
        let service = CoreAudioService(volumeIO: DirectoryListenerVolumeIO(runtime: runtime),
                                       makeDirectoryListener: runtime.factory)
        let old = DirectoryListenerCounter()
        try await service.observeChanges { old.increment() }
        runtime.fire(0)
        XCTAssertEqual(old.count, 1)
        runtime.removalResults(id: 0, statuses: [-912, -912, noErr])
        await service.stopObserving()
        XCTAssertEqual(runtime.removedIDs, [0, 1, 2, 3])
        [0, 1, 2].forEach { runtime.fire($0) }
        XCTAssertEqual(old.count, 1, "Remove failure must not keep callback delivery open.")

        let replacement = DirectoryListenerCounter()
        do {
            try await service.observeChanges { replacement.increment() }
            XCTFail("A retained failed removal must block every new registration.")
        } catch {
            guard case AudioServiceError.unavailable = error else {
                return XCTFail("Unexpected removal-retry error: \(error)")
            }
        }
        XCTAssertEqual(runtime.createdCount, 4)
        XCTAssertEqual(runtime.addedIDs, [0, 1, 2, 3])
        XCTAssertEqual(runtime.removedIDs, [0, 1, 2, 3, 0])
        runtime.fire(0)
        XCTAssertEqual(old.count, 1)
        XCTAssertEqual(replacement.count, 0)

        try await service.observeChanges { replacement.increment() }
        XCTAssertEqual(runtime.removedIDs, [0, 1, 2, 3, 0, 0], "Retry must use the originally created token, without re-registering it.")
        XCTAssertEqual(runtime.addedIDs, Array(0...7))
        XCTAssertEqual(runtime.createdCount, 8)
        XCTAssertTrue(runtime.argumentMatches.allSatisfy { $0 }, "Every native call must retain its original object/address/queue tuple.")
        runtime.fire(0)
        XCTAssertEqual(old.count, 1)
        [4, 5, 6].forEach { runtime.fire($0) }
        XCTAssertEqual(replacement.count, 3)
        await service.stopObserving()
    }

    func testBadObjectRemovalIsTerminalAndDoesNotLeaveRetryRegistration() async throws {
        let runtime = DirectoryListenerTestRuntime()
        let service = CoreAudioService(volumeIO: DirectoryListenerVolumeIO(runtime: runtime),
                                       makeDirectoryListener: runtime.factory)
        let old = DirectoryListenerCounter()
        try await service.observeChanges { old.increment() }
        runtime.removalResults(id: 0, statuses: [kAudioHardwareBadObjectError])
        await service.stopObserving()
        let replacement = DirectoryListenerCounter()

        try await service.observeChanges { replacement.increment() }

        XCTAssertEqual(runtime.removedIDs, [0, 1, 2, 3])
        XCTAssertEqual(runtime.addedIDs, Array(0...7))
        [0, 1, 2].forEach { runtime.fire($0) }
        XCTAssertEqual(old.count, 0)
        runtime.fire(4)
        XCTAssertEqual(replacement.count, 1)
        await service.stopObserving()
        XCTAssertEqual(runtime.removedIDs.filter { $0 == 0 }.count, 1)
    }

    func testStopClosesLateCallbacksAndShutdownRejectsNewRegistration() async throws {
        let runtime = DirectoryListenerTestRuntime()
        let service = CoreAudioService(volumeIO: DirectoryListenerVolumeIO(runtime: runtime),
                                       makeDirectoryListener: runtime.factory)
        let callbacks = DirectoryListenerCounter()
        try await service.observeChanges { callbacks.increment() }
        runtime.fire(0)
        XCTAssertEqual(callbacks.count, 1)
        await service.stopObserving()
        [0, 1, 2].forEach { runtime.fire($0) }
        XCTAssertEqual(callbacks.count, 1)
        service.beginShutdown()

        do {
            try await service.observeChanges { callbacks.increment() }
            XCTFail("A closed service must reject new observer installation.")
        } catch is CancellationError {
            // The irreversible gate rejects before creating another token.
        } catch { XCTFail("Unexpected shutdown error: \(error)") }
        XCTAssertEqual(runtime.createdCount, 4)
        XCTAssertEqual(runtime.addedIDs, [0, 1, 2, 3])
        XCTAssertEqual(runtime.removedIDs, [0, 1, 2, 3])
        await service.stopObserving()
        XCTAssertEqual(runtime.removedIDs, [0, 1, 2, 3], "Repeated cleanup must not repeat successful removals.")
    }
}

private final class DirectoryListenerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// All native Add/Remove calls terminate in these injected operations. The
/// callback copies remain callable after cleanup to model late HAL delivery.
/// Native block-pointer identity itself is covered by THVolumeListenerTokenTests.
private final class DirectoryListenerTestRuntime: @unchecked Sendable {
    private struct Entry {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let callback: AudioObjectPropertyListenerBlock
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var adds: [Int] = []
    private var removes: [Int] = []
    private var matches: [Bool] = []
    private var addFailures: [Int: OSStatus] = [:]
    private var removeResults: [Int: [OSStatus]] = [:]
    private var nextRemoveCallback: Int?
    private var addCallbacks = Set<Int>()

    var factory: CoreAudioService.DirectoryListenerFactory {
        { [self] object, address, queue, callback in
            makeToken(object: object, address: address, queue: queue, callback: callback)
        }
    }
    var createdCount: Int { lock.withLock { entries.count } }
    var addedIDs: [Int] { lock.withLock { adds } }
    var removedIDs: [Int] { lock.withLock { removes } }
    var argumentMatches: [Bool] { lock.withLock { matches } }

    func failAdd(id: Int, status: OSStatus) { lock.withLock { addFailures[id] = status } }
    func removalResults(id: Int, statuses: [OSStatus]) { lock.withLock { removeResults[id] = statuses } }
    func fireDuringNextRemove(id: Int) { lock.withLock { nextRemoveCallback = id } }
    func fireDuringAdd(id: Int) { lock.withLock { addCallbacks.insert(id) } }
    func selectors(for ids: [Int]) -> [AudioObjectPropertySelector] {
        lock.withLock { ids.map { entries[$0].address.mSelector } }
    }
    func areSystemGlobalMain(_ ids: [Int]) -> Bool {
        lock.withLock {
            ids.allSatisfy {
                let item = entries[$0]
                return item.object == AudioObjectID(kAudioObjectSystemObject) &&
                    item.address.mScope == kAudioObjectPropertyScopeGlobal &&
                    item.address.mElement == kAudioObjectPropertyElementMain
            }
        }
    }

    func makeToken(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
                   callback: @escaping AudioObjectPropertyListenerBlock) -> THVolumeListenerToken {
        let id = lock.withLock {
            let id = entries.count
            entries.append(Entry(object: object, address: address, queue: queue, callback: callback))
            return id
        }
        return THVolumeListenerToken(object: object, address: address, queue: queue, callback: callback,
            addOperation: { [self] object, address, queue, _ in
                recordAdd(id: id, object: object, address: address.pointee, queue: queue)
            }, removeOperation: { [self] object, address, queue, _ in
                recordRemove(id: id, object: object, address: address.pointee, queue: queue)
            })
    }

    func fire(_ id: Int) {
        let entry = lock.withLock { entries[id] }
        var address = entry.address
        withUnsafePointer(to: &address) { entry.callback(1, $0) }
    }

    private func recordAdd(id: Int, object: AudioObjectID, address: AudioObjectPropertyAddress,
                           queue: DispatchQueue) -> OSStatus {
        let (status, fireNow) = lock.withLock {
            adds.append(id)
            matches.append(tupleMatches(entries[id], object: object, address: address, queue: queue))
            return (addFailures[id] ?? noErr, addCallbacks.remove(id) != nil)
        }
        if fireNow { fire(id) }
        return status
    }

    private func recordRemove(id: Int, object: AudioObjectID, address: AudioObjectPropertyAddress,
                              queue: DispatchQueue) -> OSStatus {
        let (status, callback): (OSStatus, Int?) = lock.withLock {
            removes.append(id)
            matches.append(tupleMatches(entries[id], object: object, address: address, queue: queue))
            let callback = nextRemoveCallback
            nextRemoveCallback = nil
            var results = removeResults[id] ?? []
            let status = results.isEmpty ? noErr : results.removeFirst()
            removeResults[id] = results
            return (status, callback)
        }
        if let callback { fire(callback) }
        return status
    }

    private func tupleMatches(_ original: Entry, object: AudioObjectID,
                              address: AudioObjectPropertyAddress, queue: DispatchQueue) -> Bool {
        original.object == object && original.address.mSelector == address.mSelector &&
            original.address.mScope == address.mScope && original.address.mElement == address.mElement &&
            original.queue === queue
    }
}

/// Only the listener-facing IO is supported; no path can mutate real audio.
private final class DirectoryListenerVolumeIO: CoreAudioVolumeIO, @unchecked Sendable {
    private let runtime: DirectoryListenerTestRuntime
    private let lock = NSLock()
    private var writes = 0
    var mutationAttempts: Int { lock.withLock { writes } }
    init(runtime: DirectoryListenerTestRuntime) { self.runtime = runtime }

    func outputDevice(uid: String) throws -> AudioObjectID {
        guard uid == "volume-listener-fixture" else { throw AudioVolumeIssue.identityUnconfirmed }
        return 77
    }
    func scalar(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                element: UInt32) throws -> AudioVolumePropertyEvidence? { nil }
    func mute(_ object: AudioObjectID, element: UInt32) throws -> AudioVolumeMuteEvidence? { nil }
    func outputElements(_ object: AudioObjectID) throws -> [UInt32] { [1] }
    func hasProperty(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        object == 77 && address.mSelector == kAudioDevicePropertyVolumeScalar &&
            address.mScope == kAudioObjectPropertyScopeOutput && address.mElement == kAudioObjectPropertyElementMain
    }
    func setScalar(_ object: AudioObjectID, value: Float) -> OSStatus {
        lock.withLock { writes += 1 }
        return kAudioHardwareIllegalOperationError
    }
    func setMute(_ object: AudioObjectID, element: UInt32, value: UInt32) -> OSStatus {
        lock.withLock { writes += 1 }
        return kAudioHardwareIllegalOperationError
    }
    func addListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                     changed: @escaping @Sendable () -> Void) throws -> CoreAudioVolumeObservationState.Registration {
        let delivery = AudioVolumeListenerDelivery(changed)
        let queue = DispatchQueue(label: "test.directory-independent-volume")
        let token = runtime.makeToken(object: object, address: address, queue: queue) { _, _ in delivery.signal() }
        guard token.registerListener() == noErr else {
            delivery.close()
            throw AudioVolumeIssue.listenerUnavailable
        }
        return .init(object: object, address: address, queue: queue, token: token, delivery: delivery)
    }
    func removeListener(_ registration: CoreAudioVolumeObservationState.Registration) -> OSStatus {
        registration.token.removeListener()
    }
}
