import Foundation
import XCTest
@testable import ToneHop

@MainActor
final class AudioServiceEpochTests: XCTestCase {
    func testResetRevokesOldAdmissionAndNeverReopensShutdownOrRequestPermit() {
        let epoch = AudioServiceEpoch()
        let old = epoch.capture()
        let shutdown = AudioShutdownSignal()
        let request = AudioMutationPermit()
        XCTAssertNotNil(epoch.reset(ifCurrent: old.id))
        XCTAssertNil(epoch.reset(ifCurrent: old.id), "A duplicate or retired listener cannot reset the new service.")
        XCTAssertFalse(shutdown.performIfRunning(servicePermit: old.permit) { XCTFail("Old generation submitted.") })
        let current = epoch.capture()
        XCTAssertTrue(shutdown.performIfRunning(servicePermit: current.permit) {})
        request.cancel()
        XCTAssertFalse(shutdown.performIfRunning(permit: request, servicePermit: current.permit) { XCTFail("Reset reopened a request.") })
        shutdown.begin()
        XCTAssertFalse(shutdown.performIfRunning(servicePermit: current.permit) { XCTFail("Reset reopened shutdown.") })
        epoch.close()
        XCTAssertNil(epoch.reset(ifCurrent: current.id))
    }

    func testResetReturnsWhileAcceptedNativeCallStillMustDrain() async {
        let epoch = AudioServiceEpoch()
        let old = epoch.capture()
        let gate = AudioShutdownSignal()
        let entered = XCTestExpectation(description: "native call admitted")
        let release = DispatchSemaphore(value: 0)
        let work = Task.detached {
            gate.performIfRunning(servicePermit: old.permit) {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            }
        }
        let admission = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(admission, .completed)
        XCTAssertNotNil(epoch.reset(ifCurrent: old.id))
        XCTAssertFalse(gate.performIfRunning(servicePermit: old.permit) { XCTFail("Old continuation was admitted.") })
        let premature = XCTestExpectation(description: "drain cannot precede native return")
        premature.isInverted = true
        let drained = Task { await gate.drainSubmissions(); premature.fulfill() }
        let held = await XCTWaiter.fulfillment(of: [premature], timeout: 0.03)
        XCTAssertEqual(held, .completed)
        release.signal()
        let accepted = await work.value
        XCTAssertTrue(accepted)
        await drained.value
    }

    func testConcurrentResetCloseAndRegistrationLeaveNoPostCloseAdmission() async {
        for _ in 0..<100 {
            let epoch = AudioServiceEpoch()
            let old = epoch.capture()
            let gate = AudioShutdownSignal()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = epoch.reset(ifCurrent: old.id) }
                group.addTask { epoch.close() }
                group.addTask { _ = gate.performIfRunning(servicePermit: old.permit) {} }
            }
            XCTAssertFalse(epoch.capture().permit.isActive)
            XCTAssertNil(epoch.reset(ifCurrent: epoch.capture().id))
            XCTAssertFalse(gate.performIfRunning(servicePermit: old.permit) { XCTFail("Retired generation reopened.") })
            await gate.drainSubmissions()
        }
    }
}
