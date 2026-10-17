import Foundation
import XCTest
@testable import ToneHop

@MainActor
final class AudioShutdownSignalTests: XCTestCase {
    func testCancellationCannotDrainAcceptedSubmissionAndAllWaitersObserveRealReturn() async {
        let signal = AudioShutdownSignal()
        let trace = ShutdownSubmissionTrace()
        let entered = XCTestExpectation(description: "native submission is registered")
        let returned = XCTestExpectation(description: "native submission has returned")
        let release = DispatchSemaphore(value: 0)
        let work = Task.detached {
            let accepted = signal.performIfRunning {
                trace.record("operation")
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
                trace.record("operation-return")
            }
            returned.fulfill()
            return accepted
        }
        let admission = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(admission, .completed)
        signal.begin()
        work.cancel()
        let firstDrained = XCTestExpectation(description: "cancelled waiter still awaits the operation")
        let secondDrained = XCTestExpectation(description: "second waiter sees real return")
        let prematureDrain = XCTestExpectation(description: "neither waiter drains before native return")
        prematureDrain.isInverted = true
        let first = Task {
            await signal.drainSubmissions()
            if !trace.values().contains("operation-return") { prematureDrain.fulfill() }
            trace.record("first-drained")
            firstDrained.fulfill()
        }
        let second = Task {
            await signal.drainSubmissions()
            if !trace.values().contains("operation-return") { prematureDrain.fulfill() }
            trace.record("second-drained")
            secondDrained.fulfill()
        }
        first.cancel()
        let held = await XCTWaiter.fulfillment(of: [prematureDrain], timeout: 0.05)
        XCTAssertEqual(held, .completed)
        XCTAssertEqual(trace.values(), ["operation"])
        XCTAssertFalse(signal.performIfRunning { XCTFail("Closing cannot admit another write.") })
        release.signal()
        let completion = await XCTWaiter.fulfillment(of: [returned, firstDrained, secondDrained], timeout: 2)
        XCTAssertEqual(completion, .completed)
        let accepted = await work.value
        XCTAssertTrue(accepted)
        await first.value
        await second.value
        XCTAssertEqual(Array(trace.values().prefix(2)), ["operation", "operation-return"])
        XCTAssertEqual(Set(trace.values().suffix(2)), ["first-drained", "second-drained"])
    }

    func testClosingRacesNativeRegistrationWithoutAdmittingPostCloseWrites() async {
        for _ in 0..<50 {
            let signal = AudioShutdownSignal()
            let trace = ShutdownSubmissionTrace()
            let submission = Task.detached {
                signal.performIfRunning { trace.record("accepted-operation") }
            }
            let close = Task.detached { signal.begin() }
            let accepted = await submission.value
            await close.value
            XCTAssertTrue(signal.isShuttingDown)
            XCTAssertEqual(trace.values(), accepted ? ["accepted-operation"] : [])
            XCTAssertFalse(signal.performIfRunning { XCTFail("Post-close write was admitted.") })
            await signal.drainSubmissions()
            XCTAssertFalse(signal.performIfRunning { XCTFail("Draining reopened the gate.") })
        }
    }

    func testClosedGateNeverReopensAndEmptyDrainReturns() async {
        let signal = AudioShutdownSignal()
        XCTAssertFalse(signal.isShuttingDown)
        XCTAssertNoThrow(try signal.checkRunning())
        signal.begin()
        signal.begin()
        XCTAssertTrue(signal.isShuttingDown)
        XCTAssertThrowsError(try signal.checkRunning())
        XCTAssertFalse(signal.performIfRunning { XCTFail("Closed gate accepted a write.") })
        await signal.drainSubmissions()
        await signal.drainSubmissions()
        XCTAssertFalse(signal.performIfRunning { XCTFail("Repeated drain reopened the gate.") })
    }
}

private final class ShutdownSubmissionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ value: String) { lock.withLock { events.append(value) } }
    func values() -> [String] { lock.withLock { events } }
}
