import Foundation
import Darwin
import XCTest
@testable import ToneHop

final class AudioRouteExecutorTests: XCTestCase {
    func testNestedRunLoopDoesNotReenterQueuedActorJobAndKeepsOneThread() async {
        let actor = ExecutorFixture()
        let trace = ExecutorTrace()
        let firstStarted = XCTestExpectation(description: "first synchronous actor job entered")
        let startPumping = DispatchSemaphore(value: 0)
        let first = Task.detached { await actor.pumpFirst(trace: trace, started: firstStarted, gate: startPumping) }
        let began = await XCTWaiter.fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertEqual(began, .completed)

        let second = Task.detached { await actor.runSecond(trace: trace) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while AudioRouteExecutor.shared.queuedJobCount == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        // Release the first job only after the second job really reached the
        // executor queue, rather than assuming Task creation already enqueued it.
        XCTAssertGreaterThan(AudioRouteExecutor.shared.queuedJobCount, 0)
        startPumping.signal()
        let firstResult = await first.value
        await second.value

        XCTAssertTrue(firstResult.gateOpened)
        XCTAssertTrue(firstResult.timerFired, "The first job must actually pump the nested run loop.")
        XCTAssertTrue(firstResult.secondStillQueued, "Nested source handling must leave the next actor job queued.")
        let entries = trace.entries()
        XCTAssertEqual(entries.map(\.event), ["first-begin", "nested-timer", "first-end", "second"])
        XCTAssertEqual(Set(entries.map(\.thread)).count, 1)
        XCTAssertNotEqual(entries.first?.thread, 0)
    }
}

private actor ExecutorFixture {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        AudioRouteExecutor.shared.asUnownedSerialExecutor()
    }

    struct PumpResult: Sendable {
        let gateOpened: Bool
        let timerFired: Bool
        let secondStillQueued: Bool
    }

    func pumpFirst(trace: ExecutorTrace, started: XCTestExpectation, gate: DispatchSemaphore) -> PumpResult {
        trace.record("first-begin")
        started.fulfill()
        let gateOpened = gate.wait(timeout: .now() + 3) == .success
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.01, 0, 0, 0) { _ in
            trace.record("nested-timer")
        }!
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
        defer { CFRunLoopTimerInvalidate(timer) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        } while !trace.timerFired && ContinuousClock.now < deadline
        let queued = AudioRouteExecutor.shared.queuedJobCount > 0
        trace.record("first-end")
        return PumpResult(gateOpened: gateOpened, timerFired: trace.timerFired, secondStillQueued: queued)
    }

    func runSecond(trace: ExecutorTrace) { trace.record("second") }
}

private final class ExecutorTrace: @unchecked Sendable {
    struct Entry: Sendable {
        let event: String
        let thread: UInt64
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []

    func record(_ event: String) {
        var thread: UInt64 = 0
        pthread_threadid_np(nil, &thread)
        lock.lock()
        recorded.append(Entry(event: event, thread: thread))
        lock.unlock()
    }

    func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var timerFired: Bool { entries().contains { $0.event == "nested-timer" } }
}
