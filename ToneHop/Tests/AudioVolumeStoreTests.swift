import Foundation
import XCTest
@testable import ToneHop

@MainActor
final class AudioVolumeStoreTests: XCTestCase {
    func testEveryBindingKeepsARowAndUnsupportedOrUnresolvedRowsCannotWrite() async {
        let supported = target("supported")
        let unsupported = target("unsupported")
        let provider = VolumeStoreProvider(targets: [supported, unsupported])
        provider.snapshots[unsupported] = snapshot(unsupported, value: nil, capability: .unavailable(.unsupported))
        let resolver = VolumeStoreResolver(targets: [supported, unsupported])
        let store = makeStore(provider, resolver)
        store.updateBindings([
            AudioVolumeBinding(deviceID: supported.deviceID, target: supported),
            AudioVolumeBinding(deviceID: unsupported.deviceID, target: unsupported),
            AudioVolumeBinding(deviceID: "unconnected", target: nil, unavailableReason: .notConnected)
        ])
        await store.drain()

        XCTAssertEqual(store.rows.count, 3)
        XCTAssertTrue(store.state(for: supported.deviceID)?.canWrite == true)
        XCTAssertEqual(store.state(for: unsupported.deviceID)?.issue, .unsupported)
        XCTAssertNil(store.state(for: unsupported.deviceID)?.value)
        XCTAssertEqual(store.state(for: "unconnected")?.issue, .notConnected)
        XCTAssertNil(store.failureEvent, "Capability limitations and identity waiting are not failed operations.")
        store.setVolume(0.6, for: unsupported.deviceID, isFinal: true)
        store.setVolume(0.6, for: "unconnected", isFinal: true)
        await store.drain()
        XCTAssertTrue(resolver.calls.isEmpty)
        XCTAssertTrue(provider.writes.isEmpty)
        await finish(store, provider)
    }

    func testDraggingKeepsOnlyLatestPendingValueAndLateResultCannotReplaceItsPreview() async {
        let target = target("speaker")
        let provider = VolumeStoreProvider(targets: [target])
        let resolver = VolumeStoreResolver(targets: [target])
        let store = makeStore(provider, resolver)
        store.updateTargets([target.deviceID: target])
        await store.drain()
        provider.writeSuspension = .afterAdmission

        store.beginEditing(target.deviceID)
        store.setVolume(0.4, for: target.deviceID)
        await waitForState("first write is held after admission") { provider.pendingWriteCount == 1 }
        store.setVolume(0.6, for: target.deviceID)
        store.setVolume(0.9, for: target.deviceID, isFinal: true)
        XCTAssertEqual(store.state(for: target.deviceID)?.draftValue, 0.9)
        XCTAssertEqual(provider.writes.map(\.value), [0.4])

        provider.releaseFirstWrite()
        await waitForState("only the final pending value is submitted") { provider.writes.count == 2 }
        XCTAssertEqual(provider.writes.map(\.value), [0.4, 0.9])
        XCTAssertEqual(store.state(for: target.deviceID)?.value, 0.9)
        XCTAssertEqual(store.state(for: target.deviceID)?.snapshot?.value, 0.2,
                       "A cancelled result cannot be published over a newer user request.")
        XCTAssertEqual(resolver.calls, [target.deviceID, target.deviceID])

        provider.releaseAllWrites()
        await store.drain()
        XCTAssertEqual(store.state(for: target.deviceID)?.snapshot?.value, 0.9)
        XCTAssertNil(store.state(for: target.deviceID)?.draftValue)
        XCTAssertFalse(store.state(for: target.deviceID)?.isWriting == true)
        await finish(store, provider)
    }

    func testLateExternalReadCannotOverwriteNewerCompletedWrite() async {
        let target = target("speaker")
        let provider = VolumeStoreProvider(targets: [target])
        let store = makeStore(provider, VolumeStoreResolver(targets: [target]))
        store.updateTargets([target.deviceID: target])
        await store.drain()
        provider.holdReads = true
        store.refresh()
        await waitForState("older external read is held") { provider.pendingReadCount == 1 }

        store.setVolume(0.85, for: target.deviceID, isFinal: true)
        await waitForState("newer write is confirmed") { store.state(for: target.deviceID)?.snapshot?.value == 0.85 }
        provider.releaseFirstRead(with: snapshot(target, value: 0.1))
        await store.drain()

        XCTAssertEqual(store.state(for: target.deviceID)?.value, 0.85)
        XCTAssertNil(store.state(for: target.deviceID)?.issue)
        XCTAssertEqual(provider.admittedWrites.map(\.value), [0.85])
        await finish(store, provider)
    }

    func testNewGenerationWithSameUIDRejectsOldWriteResultAndOldPermit() async {
        let original = target("speaker")
        let replacement = AudioVolumeTarget(deviceID: original.deviceID, uid: original.uid)
        let provider = VolumeStoreProvider(targets: [original, replacement])
        provider.snapshots[replacement] = snapshot(replacement, value: 0.3)
        let resolver = VolumeStoreResolver(targets: [original])
        let store = makeStore(provider, resolver)
        store.updateTargets([original.deviceID: original])
        await store.drain()
        provider.writeSuspension = .afterAdmission
        store.setVolume(0.8, for: original.deviceID, isFinal: true)
        await waitForState("old generation write is held") { provider.pendingWriteCount == 1 }

        resolver.targets[replacement.deviceID] = replacement
        store.updateTargets([replacement.deviceID: replacement])
        XCTAssertEqual(store.state(for: replacement.deviceID)?.target, replacement)
        XCTAssertFalse(store.state(for: replacement.deviceID)?.canWrite == true)
        assertFirstPermitCancelled(provider)
        provider.releaseFirstWrite()
        await store.drain()
        XCTAssertNotEqual(store.state(for: replacement.deviceID)?.snapshot?.target, original)
        XCTAssertNotEqual(store.state(for: replacement.deviceID)?.value, 0.8)
        XCTAssertEqual(store.state(for: replacement.deviceID)?.snapshot, provider.snapshots[replacement],
                       "The replacement must be read when the old writer returns, without waiting for polling.")
        XCTAssertEqual(provider.reads.map(\.target), [original, replacement])
        XCTAssertEqual(provider.admittedWrites.map(\.target), [original])
        await finish(store, provider)
    }

    func testNewGenerationWithSameUIDRejectsOldReadResult() async {
        let original = target("speaker")
        let replacement = AudioVolumeTarget(deviceID: original.deviceID, uid: original.uid)
        let provider = VolumeStoreProvider(targets: [original, replacement])
        provider.holdReads = true
        let resolver = VolumeStoreResolver(targets: [original])
        let store = makeStore(provider, resolver)
        store.updateTargets([original.deviceID: original])
        await waitForState("old read is held") { provider.pendingReadCount == 1 }

        resolver.targets[replacement.deviceID] = replacement
        provider.holdReads = false
        store.updateTargets([replacement.deviceID: replacement])
        provider.releaseFirstRead(with: snapshot(original, value: 0.95))
        await store.drain()
        XCTAssertEqual(store.state(for: replacement.deviceID)?.target, replacement)
        XCTAssertNotEqual(store.state(for: replacement.deviceID)?.snapshot?.target, original)
        XCTAssertEqual(store.state(for: replacement.deviceID)?.snapshot?.target, replacement,
                       "The new generation must be read as soon as the cancelled reader actually returns.")
        XCTAssertEqual(provider.reads.map(\.target), [original, replacement])
        XCTAssertTrue(provider.writes.isEmpty)
        await finish(store, provider)
    }

    func testPauseCancelsQueuedPermitAndDiscardsPendingValueButDrainWaitsForReturn() async {
        let target = target("speaker")
        let provider = VolumeStoreProvider(targets: [target])
        let resolver = VolumeStoreResolver(targets: [target])
        let store = makeStore(provider, resolver)
        store.updateTargets([target.deviceID: target])
        await store.drain()
        provider.writeSuspension = .beforeAdmission
        store.setVolume(0.5, for: target.deviceID, isFinal: true)
        await waitForState("write is queued before its mutation registration") { provider.pendingWriteCount == 1 }
        store.setVolume(0.7, for: target.deviceID, isFinal: true)

        store.pause()
        XCTAssertTrue(store.isPaused)
        XCTAssertNil(store.state(for: target.deviceID)?.draftValue)
        assertFirstPermitCancelled(provider)
        store.setVolume(0.9, for: target.deviceID, isFinal: true)
        await verifyDrainWaitsForWriteReturn(store, provider)

        XCTAssertEqual(provider.writes.map(\.value), [0.5])
        XCTAssertTrue(provider.admittedWrites.isEmpty, "The queued request must not register after pause returns.")
        XCTAssertEqual(resolver.calls, [target.deviceID])
        XCTAssertEqual(store.state(for: target.deviceID)?.snapshot?.value, 0.2)
        await finish(store, provider)
    }

    func testPauseCannotUndoAcceptedWriteAndWaitsForItsRealResult() async {
        let target = target("speaker")
        let provider = VolumeStoreProvider(targets: [target])
        let store = makeStore(provider, VolumeStoreResolver(targets: [target]))
        store.updateTargets([target.deviceID: target])
        await store.drain()
        provider.writeSuspension = .afterAdmission
        store.setVolume(0.75, for: target.deviceID, isFinal: true)
        await waitForState("admitted write is waiting for its result") { provider.pendingWriteCount == 1 }

        store.pause()
        assertFirstPermitCancelled(provider)
        XCTAssertEqual(provider.admittedWrites.map(\.value), [0.75])
        await verifyDrainWaitsForWriteReturn(store, provider)
        XCTAssertEqual(provider.returnedWriteIDs.count, 1)
        XCTAssertEqual(provider.snapshots[target]?.value, 0.75, "Cancellation does not undo an accepted remote effect.")
        XCTAssertEqual(store.state(for: target.deviceID)?.snapshot?.value, 0.2,
                       "A result arriving after pause must not refresh the displayed capability.")
        await finish(store, provider)
    }

    func testResumeRequiresFreshReadBeforeAcceptingAnyNewWrite() async {
        let target = target("speaker")
        let provider = VolumeStoreProvider(targets: [target])
        let resolver = VolumeStoreResolver(targets: [target])
        let store = makeStore(provider, resolver)
        store.updateTargets([target.deviceID: target])
        await store.drain()
        store.pause()
        await store.drain()
        provider.holdReads = true
        store.resume()
        XCTAssertNil(store.state(for: target.deviceID)?.snapshot)
        XCTAssertFalse(store.state(for: target.deviceID)?.canWrite == true)
        store.setVolume(0.9, for: target.deviceID, isFinal: true)
        await waitForState("resume starts a fresh capability read") { provider.pendingReadCount == 1 }
        provider.releaseFirstRead(with: snapshot(target, value: 0.35, capability: .unavailable(.readOnly)))
        await store.drain()
        store.setVolume(0.9, for: target.deviceID, isFinal: true)
        await store.drain()

        XCTAssertEqual(store.state(for: target.deviceID)?.value, 0.35)
        XCTAssertEqual(store.state(for: target.deviceID)?.issue, .readOnly)
        XCTAssertTrue(provider.writes.isEmpty)
        XCTAssertTrue(resolver.calls.isEmpty)

        provider.holdReads = false
        provider.snapshots[target] = snapshot(target, value: 0.35)
        store.refresh()
        await store.drain()
        store.setVolume(0.6, for: target.deviceID, isFinal: true)
        await store.drain()
        XCTAssertEqual(provider.admittedWrites.map(\.value), [0.6])
        await finish(store, provider)
    }

    func testResolverGenerationMismatchPreventsProviderWriteAndReportsIdentityChange() async {
        let current = target("speaker")
        let changed = AudioVolumeTarget(deviceID: current.deviceID, uid: current.uid)
        let provider = VolumeStoreProvider(targets: [current])
        let resolver = VolumeStoreResolver(targets: [changed])
        let store = makeStore(provider, resolver)
        store.updateTargets([current.deviceID: current])
        await store.drain()
        store.setVolume(0.8, for: current.deviceID, isFinal: true)
        await store.drain()

        XCTAssertEqual(resolver.calls, [current.deviceID])
        XCTAssertTrue(provider.writes.isEmpty)
        XCTAssertEqual(store.state(for: current.deviceID)?.issue, .identityChanged)
        XCTAssertEqual(store.state(for: current.deviceID)?.value, 0.2)
        XCTAssertNil(store.state(for: current.deviceID)?.draftValue)
        await finish(store, provider)
    }

    func testInvalidWritableReadbacksDisableAdmissionWithoutRetryingTheRead() async {
        let invalidValues: [Float?] = [nil, .nan, .infinity, -0.1, 1.1]
        for invalidValue in invalidValues {
            let target = target("speaker")
            let provider = VolumeStoreProvider(targets: [target])
            provider.snapshots[target] = snapshot(target, value: invalidValue)
            let resolver = VolumeStoreResolver(targets: [target])
            let store = makeStore(provider, resolver)
            store.updateTargets([target.deviceID: target])
            await store.drain()

            XCTAssertEqual(store.state(for: target.deviceID)?.issue, .invalidReadback)
            XCTAssertNil(store.state(for: target.deviceID)?.value)
            XCTAssertFalse(store.state(for: target.deviceID)?.canWrite == true)
            store.setVolume(0.6, for: target.deviceID, isFinal: true)
            await store.drain()
            XCTAssertTrue(provider.writes.isEmpty)
            XCTAssertTrue(resolver.calls.isEmpty)
            XCTAssertEqual(provider.reads.count, 1, "A bad readback must not create an immediate retry loop.")
            await finish(store, provider)
        }
    }

    func testSnapshotForDifferentTargetCannotEnableTheRequestedRow() async {
        let target = target("speaker")
        let other = self.target("other")
        let provider = VolumeStoreProvider(targets: [target])
        provider.snapshots[target] = snapshot(other, value: 0.5)
        let resolver = VolumeStoreResolver(targets: [target])
        let store = makeStore(provider, resolver)
        store.updateTargets([target.deviceID: target])
        await store.drain()

        XCTAssertEqual(store.state(for: target.deviceID)?.issue, .identityChanged)
        XCTAssertFalse(store.state(for: target.deviceID)?.canWrite == true)
        XCTAssertNil(store.state(for: target.deviceID)?.value)
        store.setVolume(0.6, for: target.deviceID, isFinal: true)
        await store.drain()
        XCTAssertTrue(provider.writes.isEmpty)
        XCTAssertTrue(resolver.calls.isEmpty)
        await finish(store, provider)
    }

    func testResolverFailurePreventsProviderWriteWithoutSubstitutingAnotherTarget() async {
        let first = target("first")
        let other = target("other")
        let provider = VolumeStoreProvider(targets: [first, other])
        let resolver = VolumeStoreResolver(targets: [first, other])
        resolver.failure = .identityUnconfirmed
        let store = makeStore(provider, resolver)
        store.updateTargets([first.deviceID: first, other.deviceID: other])
        await store.drain()
        store.setVolume(0.8, for: first.deviceID, isFinal: true)
        await store.drain()

        XCTAssertEqual(resolver.calls, [first.deviceID])
        XCTAssertTrue(provider.writes.isEmpty)
        XCTAssertEqual(store.state(for: first.deviceID)?.issue, .identityUnconfirmed)
        XCTAssertNil(store.state(for: other.deviceID)?.issue)
        XCTAssertEqual(store.state(for: other.deviceID)?.value, 0.2)
        await finish(store, provider)
    }

    func testExternalNotificationRefreshesValuesAndCapabilitiesWithoutAnyWrite() async {
        let first = target("first")
        let other = target("other")
        let provider = VolumeStoreProvider(targets: [first, other])
        let resolver = VolumeStoreResolver(targets: [first, other])
        let store = makeStore(provider, resolver)
        store.updateTargets([first.deviceID: first, other.deviceID: other])
        await store.drain()
        provider.snapshots[first] = snapshot(first, value: 0.65)
        provider.snapshots[other] = snapshot(other, value: 0.4, capability: .unavailable(.readOnly))
        provider.signalChange()
        await waitForState("the injected invalidation refreshes both device rows") {
            store.state(for: first.deviceID)?.value == 0.65 && store.state(for: other.deviceID)?.issue == .readOnly
        }
        await store.drain()
        XCTAssertFalse(store.state(for: other.deviceID)?.canWrite == true)
        XCTAssertTrue(provider.writes.isEmpty)
        XCTAssertTrue(resolver.calls.isEmpty)
        let lateCallback = provider.onChange
        await finish(store, provider)
        let readsAfterClose = provider.reads.count
        lateCallback?()
        await Task.yield()
        await store.drain()
        XCTAssertEqual(provider.reads.count, readsAfterClose)
        XCTAssertEqual(provider.stopObservationCount, 1)
    }

    func testFailedWriteReconcilesRealValueAndDoesNotOverwriteAnotherRowsError() async {
        let first = target("first")
        let other = target("other")
        let provider = VolumeStoreProvider(targets: [first, other])
        let store = makeStore(provider, VolumeStoreResolver(targets: [first, other]))
        store.updateTargets([first.deviceID: first, other.deviceID: other])
        await store.drain()
        provider.snapshots[first] = snapshot(first, value: 0.3)
        provider.writeFailures[first] = .writeFailed(-50)
        store.setVolume(0.8, for: first.deviceID, isFinal: true)
        await store.drain()
        XCTAssertEqual(store.state(for: first.deviceID)?.issue, .writeFailed(-50))
        XCTAssertEqual(store.state(for: first.deviceID)?.value, 0.3)
        XCTAssertNil(store.state(for: first.deviceID)?.draftValue)
        XCTAssertNil(store.state(for: other.deviceID)?.issue)

        store.setVolume(0.55, for: other.deviceID, isFinal: true)
        await store.drain()
        XCTAssertEqual(store.state(for: first.deviceID)?.issue, .writeFailed(-50))
        XCTAssertEqual(store.state(for: first.deviceID)?.value, 0.3)
        XCTAssertEqual(store.state(for: other.deviceID)?.value, 0.55)
        XCTAssertNil(store.state(for: other.deviceID)?.issue)
        XCTAssertEqual(provider.admittedWrites.map(\.target), [other])
        XCTAssertEqual(provider.writes.map(\.target), [first, other], "Reconciliation must never retry a setter.")
        await finish(store, provider)
    }

    func testWriteFailureSurvivesRefreshAndRefreshTriggeredByAnotherRowsCancelledWrite() async {
        let failed = target("failed")
        let other = target("other")
        let provider = VolumeStoreProvider(targets: [failed, other])
        let store = makeStore(provider, VolumeStoreResolver(targets: [failed, other]))
        store.updateTargets([failed.deviceID: failed, other.deviceID: other])
        await store.drain()
        provider.writeFailures[failed] = .writeFailed(-50)
        store.setVolume(0.8, for: failed.deviceID, isFinal: true)
        await store.drain()
        XCTAssertEqual(store.state(for: failed.deviceID)?.issue, .writeFailed(-50))

        provider.snapshots[failed] = snapshot(failed, value: 0.35)
        store.refresh()
        await store.drain()
        XCTAssertEqual(store.state(for: failed.deviceID)?.value, 0.35)
        XCTAssertEqual(store.state(for: failed.deviceID)?.issue, .writeFailed(-50),
                       "A successful background read updates the value without erasing the failed user action.")

        provider.writeSuspension = .afterAdmission
        store.setVolume(0.55, for: other.deviceID, isFinal: true)
        await waitForState("the other row has an admitted write awaiting its result") { provider.pendingWriteCount == 1 }
        provider.snapshots[failed] = snapshot(failed, value: 0.4)
        store.setVolume(0.75, for: other.deviceID, isFinal: true)
        provider.releaseFirstWrite()
        await waitForState("cancelled writer completion refreshes the failed row and starts the latest write") {
            provider.writes.count == 3 && store.state(for: failed.deviceID)?.value == 0.4 &&
                store.state(for: failed.deviceID)?.isReading == false
        }

        XCTAssertEqual(store.state(for: failed.deviceID)?.issue, .writeFailed(-50),
                       "Refreshing after another row's cancellation must preserve this row's operation error.")
        XCTAssertEqual(store.state(for: other.deviceID)?.value, 0.75)
        provider.releaseAllWrites()
        await store.drain()
        XCTAssertEqual(store.state(for: failed.deviceID)?.issue, .writeFailed(-50))
        XCTAssertNil(store.state(for: other.deviceID)?.issue)
        XCTAssertEqual(provider.writes.filter { $0.target == failed }.count, 1,
                       "Neither refresh path may retry the failed setter.")
        XCTAssertEqual(provider.admittedWrites.map(\.target), [other, other])
        await finish(store, provider)
    }

    func testUnconfirmedMutedWriteSurvivesRefreshAndExternalUnmuteWithoutReplay() async {
        let device = target("muted-output")
        let provider = VolumeStoreProvider(targets: [device])
        let store = makeStore(provider, VolumeStoreResolver(targets: [device]))
        store.updateTargets([device.deviceID: device])
        await store.drain()
        provider.snapshots[device] = AudioVolumeSnapshot(target: device, value: 0,
            capability: .writable(.main), mute: .muted, canUnmute: true)
        provider.writeFailures[device] = .mutedVolumeUnconfirmed
        store.setVolume(0.65, for: device.deviceID, isFinal: true)
        await store.drain()
        XCTAssertEqual(store.state(for: device.deviceID)?.issue, .mutedVolumeUnconfirmed)
        XCTAssertEqual(store.state(for: device.deviceID)?.value, 0)

        store.refresh()
        await store.drain()
        XCTAssertEqual(store.state(for: device.deviceID)?.issue, .mutedVolumeUnconfirmed)
        provider.snapshots[device] = snapshot(device, value: 0.6875)
        store.refresh()
        await store.drain()
        XCTAssertEqual(store.state(for: device.deviceID)?.value, 0.6875)
        XCTAssertEqual(store.state(for: device.deviceID)?.issue, .unmutedVolumeUnconfirmed)
        XCTAssertEqual(provider.writes.count, 1, "External unmute must not replay the failed request.")
        await finish(store, provider)
    }

    func testGenericWriteFailureSurvivesCapabilityAndReadRecoveryUntilConfirmedRetry() async {
        let device = target("failed-output")
        let provider = VolumeStoreProvider(targets: [device])
        let store = makeStore(provider, VolumeStoreResolver(targets: [device]))
        store.updateTargets([device.deviceID: device])
        await store.drain()
        provider.genericWriteFailures[device] = NSError(domain: "InjectedWrite", code: -71)
        store.setVolume(0.8, for: device.deviceID, isFinal: true)
        await store.drain()
        XCTAssertEqual(store.state(for: device.deviceID)?.issue, .writeFailed(-71))
        XCTAssertEqual(store.state(for: device.deviceID)?.value, 0.2)
        let writeFailureEvent = store.failureEvent
        XCTAssertEqual(writeFailureEvent?.message, AudioVolumeIssue.writeFailed(-71).localizedDescription)

        provider.snapshots[device] = snapshot(device, value: 0.3, capability: .unavailable(.readOnly))
        store.refresh()
        await store.drain()
        XCTAssertFalse(store.state(for: device.deviceID)?.canWrite == true)
        XCTAssertEqual(store.state(for: device.deviceID)?.issue, .writeFailed(-71))
        XCTAssertEqual(store.failureEvent, writeFailureEvent, "A capability change does not replay the retained write failure.")
        provider.readFailures[device] = NSError(domain: "InjectedRead", code: -72)
        store.refresh()
        await store.drain()
        XCTAssertNil(store.state(for: device.deviceID)?.value)
        XCTAssertEqual(store.state(for: device.deviceID)?.issue, .writeFailed(-71))
        let readFailureEvent = store.failureEvent
        XCTAssertNotEqual(readFailureEvent?.id, writeFailureEvent?.id)
        XCTAssertEqual(readFailureEvent?.message, AudioVolumeIssue.readFailed(-72).localizedDescription)
        store.refresh()
        await store.drain()
        XCTAssertEqual(store.failureEvent, readFailureEvent, "The same continuing read failure is not replayed on polling.")
        provider.readFailures[device] = nil
        provider.snapshots[device] = snapshot(device, value: 0.4)
        store.refresh()
        await store.drain()
        XCTAssertEqual(store.state(for: device.deviceID)?.value, 0.4)
        XCTAssertEqual(store.state(for: device.deviceID)?.issue, .writeFailed(-71))
        XCTAssertEqual(provider.writes.count, 1, "Background recovery never retries a setter.")
        XCTAssertEqual(store.failureEvent, readFailureEvent)

        provider.genericWriteFailures[device] = nil
        provider.writeSuspension = .afterAdmission
        store.setVolume(0.65, for: device.deviceID, isFinal: true)
        await waitForState("the explicit retry awaits real completion") { provider.pendingWriteCount == 1 }
        XCTAssertEqual(store.state(for: device.deviceID)?.issue, .writeFailed(-71),
                       "The preview cannot declare the previous failure repaired.")
        provider.releaseAllWrites()
        await store.drain()
        XCTAssertNil(store.state(for: device.deviceID)?.issue)
        XCTAssertEqual(store.state(for: device.deviceID)?.value, 0.65)
        XCTAssertEqual(provider.writes.count, 2)
        XCTAssertEqual(store.failureEvent, readFailureEvent, "Successful reconciliation emits no failure notification.")
        await finish(store, provider)
    }

    func testRepeatedVolumeWriteFailuresHaveDistinctEventsAndOrdinaryRefreshDoesNotReplay() async throws {
        let device = target("repeated-failure")
        let provider = VolumeStoreProvider(targets: [device])
        let store = makeStore(provider, VolumeStoreResolver(targets: [device]))
        store.updateTargets([device.deviceID: device])
        await store.drain()
        provider.writeFailures[device] = .writeFailed(-50)
        store.setVolume(0.8, for: device.deviceID, isFinal: true)
        await store.drain()
        let first = try XCTUnwrap(store.failureEvent)
        store.setVolume(0.8, for: device.deviceID, isFinal: true)
        await store.drain()
        let second = try XCTUnwrap(store.failureEvent)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.message, second.message)
        store.refresh()
        await store.drain()
        XCTAssertEqual(store.failureEvent, second)
        XCTAssertEqual(provider.writes.count, 2, "Only the two explicit requests attempt a write.")
        await finish(store, provider)
    }

    func testHiddenVolumePollingStopsForTenSecondsAndListenersStillRefresh() async throws {
        let first = target("first")
        let provider = VolumeStoreProvider(targets: [first])
        let resolver = VolumeStoreResolver(targets: [first])
        let store = makeStore(provider, resolver, pollingInterval: .milliseconds(25))
        store.setPollingActive(false)
        store.updateTargets([first.deviceID: first])
        await store.drain()
        let settled = provider.reads.count
        try await Task.sleep(for: .seconds(10))
        XCTAssertEqual(provider.reads.count, settled, "A hidden panel must not poll bound volumes.")

        provider.snapshots[first] = snapshot(first, value: 0.7)
        provider.signalChange()
        await waitForState("A hidden listener change updates the menu bar's value") {
            store.state(for: first.deviceID)?.value == 0.7
        }
        let beforeOpening = provider.reads.count
        store.setPollingActive(true)
        store.setPollingActive(false)
        store.setPollingActive(true)
        await waitForState("A rapid reopen retains its periodic reader") { provider.reads.count >= beforeOpening + 3 }
        store.setPollingActive(false)
        await store.drain()
        let hidden = provider.reads.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(provider.reads.count, hidden)
        XCTAssertTrue(provider.writes.isEmpty)
        await finish(store, provider)
    }

    func testVolumeActivationReadsImmediatelyWithoutWaitingForTheInterval() async throws {
        let first = target("first")
        let provider = VolumeStoreProvider(targets: [first])
        let resolver = VolumeStoreResolver(targets: [first])
        let store = makeStore(provider, resolver, pollingInterval: .seconds(30))
        store.setPollingActive(false)
        store.updateTargets([first.deviceID: first])
        await store.drain()
        let beforeOpening = provider.reads.count
        store.setPollingActive(true)
        await waitForState("Opening reads before the 30-second interval") { provider.reads.count > beforeOpening }
        await finish(store, provider)
    }

    func testHiddenVolumeObserverFailurePollsUntilObservationRecoversOnResume() async throws {
        let first = target("first")
        let provider = VolumeStoreProvider(targets: [first])
        provider.failObservation = true
        let resolver = VolumeStoreResolver(targets: [first])
        let store = makeStore(provider, resolver, pollingInterval: .milliseconds(10))
        store.setPollingActive(false)
        store.updateTargets([first.deviceID: first])
        await waitForState("Missing listeners retain hidden fallback") {
            store.observationIssue == .listenerUnavailable && provider.reads.count >= 4
        }

        store.pause()
        await store.drain()
        let paused = provider.reads.count
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.reads.count, paused)
        provider.failObservation = false
        store.resume()
        await store.drain()
        XCTAssertNil(store.observationIssue)
        let recovered = provider.reads.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(provider.reads.count, recovered, "Successful replacement listeners stop the hidden fallback.")
        provider.snapshots[first] = snapshot(first, value: 0.6)
        provider.signalChange()
        await waitForState("The replacement listener remains active while hidden") {
            store.state(for: first.deviceID)?.value == 0.6
        }
        await finish(store, provider)
    }

    private func target(_ id: String) -> AudioVolumeTarget {
        AudioVolumeTarget(deviceID: "hal:\(id)", uid: id)
    }

    private func snapshot(_ target: AudioVolumeTarget, value: Float?,
                          capability: AudioVolumeCapability = .writable(.main)) -> AudioVolumeSnapshot {
        AudioVolumeSnapshot(target: target, value: value, capability: capability, mute: .unmuted)
    }

    private func makeStore(_ provider: VolumeStoreProvider, _ resolver: VolumeStoreResolver,
                           pollingInterval: Duration = .seconds(3_600)) -> AudioVolumeStore {
        AudioVolumeStore(provider: provider, resolveTarget: { try resolver.resolve($0) },
                         throttle: .zero, pollingInterval: pollingInterval)
    }

    private func assertFirstPermitCancelled(_ provider: VolumeStoreProvider,
                                           file: StaticString = #filePath, line: UInt = #line) {
        guard let permit = provider.writes.first?.permit else {
            XCTFail("Expected the provider to have received a request permit.", file: file, line: line)
            return
        }
        let gate = AudioShutdownSignal()
        XCTAssertFalse(gate.performIfRunning(permit: permit) {},
                       "The old request permit must synchronously reject new registrations.", file: file, line: line)
    }

    private func verifyDrainWaitsForWriteReturn(_ store: AudioVolumeStore, _ provider: VolumeStoreProvider,
                                               file: StaticString = #filePath, line: UInt = #line) async {
        let started = XCTestExpectation(description: "store drain entered")
        let premature = XCTestExpectation(description: "drain must not finish while provider result is held")
        premature.isInverted = true
        let completed = XCTestExpectation(description: "store drain observed the actual provider return")
        let draining = Task {
            started.fulfill()
            await store.drain()
            if provider.pendingWriteCount != 0 { premature.fulfill() }
            completed.fulfill()
        }
        let entered = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(entered, .completed, file: file, line: line)
        draining.cancel()
        let held = await XCTWaiter.fulfillment(of: [premature], timeout: 0.03)
        XCTAssertEqual(held, .completed, file: file, line: line)
        provider.releaseAllWrites()
        let returned = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(returned, .completed, file: file, line: line)
        await draining.value
    }

    private func waitForState(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                              _ predicate: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate(), description, file: file, line: line)
    }

    private func finish(_ store: AudioVolumeStore, _ provider: VolumeStoreProvider) async {
        // Release controlled continuations even after a failed assertion; no
        // test leaves a held provider operation or polling task behind.
        store.pause()
        provider.holdReads = false
        provider.writeSuspension = .none
        provider.releaseAllReads()
        provider.releaseAllWrites()
        await store.shutdown()
    }
}

/// All provider state is isolated to MainActor. The continuations suspend the
/// caller without blocking MainActor and intentionally ignore Task.cancel so
/// tests can distinguish cancellation from an operation's actual return.
@MainActor
private final class VolumeStoreProvider: AudioVolumeProviding {
    enum WriteSuspension { case none, beforeAdmission, afterAdmission }
    struct WriteCall {
        let id: UUID
        let target: AudioVolumeTarget
        let value: Float
        let permit: AudioMutationPermit
    }
    struct ReadCall {
        let id: UUID
        let target: AudioVolumeTarget
    }

    var snapshots: [AudioVolumeTarget: AudioVolumeSnapshot] = [:]
    var writeFailures: [AudioVolumeTarget: AudioVolumeIssue] = [:]
    var genericWriteFailures: [AudioVolumeTarget: NSError] = [:]
    var readFailures: [AudioVolumeTarget: NSError] = [:]
    var holdReads = false
    var failObservation = false
    var writeSuspension: WriteSuspension = .none
    private(set) var reads: [ReadCall] = []
    private(set) var writes: [WriteCall] = []
    private(set) var admittedWrites: [WriteCall] = []
    private(set) var returnedWriteIDs: [UUID] = []
    private(set) var onChange: (@Sendable () -> Void)?
    private(set) var stopObservationCount = 0
    private var pendingReads: [UUID: CheckedContinuation<AudioVolumeSnapshot, any Error>] = [:]
    private var pendingWrites: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let gate = AudioShutdownSignal()

    var pendingReadCount: Int { pendingReads.count }
    var pendingWriteCount: Int { pendingWrites.count }

    init(targets: [AudioVolumeTarget]) {
        for target in targets {
            snapshots[target] = AudioVolumeSnapshot(target: target, value: 0.2,
                                                    capability: .writable(.main), mute: .unmuted)
        }
    }

    func readVolume(for target: AudioVolumeTarget) async throws -> AudioVolumeSnapshot {
        let call = ReadCall(id: UUID(), target: target)
        reads.append(call)
        if let failure = readFailures[target] { throw failure }
        if holdReads {
            return try await withCheckedThrowingContinuation { pendingReads[call.id] = $0 }
        }
        guard let snapshot = snapshots[target] else { throw AudioVolumeIssue.identityUnconfirmed }
        return snapshot
    }

    func setVolume(_ value: Float, for target: AudioVolumeTarget,
                   permit: AudioMutationPermit) async throws -> AudioVolumeWriteResult {
        let call = WriteCall(id: UUID(), target: target, value: value, permit: permit)
        writes.append(call)
        defer { returnedWriteIDs.append(call.id) }
        let suspension = writeSuspension
        if suspension == .beforeAdmission {
            await withCheckedContinuation { pendingWrites[call.id] = $0 }
        }
        if let failure = writeFailures[target] { throw failure }
        if let failure = genericWriteFailures[target] { throw failure }
        guard let old = snapshots[target] else { throw AudioVolumeIssue.identityUnconfirmed }
        let updated = AudioVolumeSnapshot(target: target, value: value, capability: old.capability,
                                          mute: old.mute, canUnmute: old.canUnmute)
        let accepted = gate.performIfRunning(permit: permit) {
            admittedWrites.append(call)
            snapshots[target] = updated
        }
        guard accepted else { throw CancellationError() }
        if suspension == .afterAdmission {
            await withCheckedContinuation { pendingWrites[call.id] = $0 }
        }
        return AudioVolumeWriteResult(snapshot: updated)
    }

    func observeVolumeChanges(targets: [AudioVolumeTarget], changed: @escaping @Sendable () -> Void) async throws {
        if failObservation { throw AudioVolumeIssue.listenerUnavailable }
        onChange = changed
    }

    func stopObservingVolume() async {
        stopObservationCount += 1
        onChange = nil
    }

    func signalChange() { onChange?() }

    func releaseFirstWrite() {
        guard let id = writes.first(where: { pendingWrites[$0.id] != nil })?.id else { return }
        pendingWrites.removeValue(forKey: id)?.resume()
    }

    func releaseAllWrites() {
        let continuations = Array(pendingWrites.values)
        pendingWrites.removeAll()
        continuations.forEach { $0.resume() }
    }

    func releaseFirstRead(with snapshot: AudioVolumeSnapshot) {
        guard let id = reads.first(where: { pendingReads[$0.id] != nil })?.id else { return }
        pendingReads.removeValue(forKey: id)?.resume(returning: snapshot)
    }

    func releaseAllReads() {
        let continuations = Array(pendingReads.values)
        pendingReads.removeAll()
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class VolumeStoreResolver {
    var targets: [String: AudioVolumeTarget]
    var failure: AudioVolumeIssue?
    private(set) var calls: [String] = []

    init(targets: [AudioVolumeTarget]) {
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.deviceID, $0) })
    }

    func resolve(_ deviceID: String) throws -> AudioVolumeTarget {
        calls.append(deviceID)
        if let failure { throw failure }
        guard let target = targets[deviceID] else { throw AudioVolumeIssue.identityUnconfirmed }
        return target
    }
}
