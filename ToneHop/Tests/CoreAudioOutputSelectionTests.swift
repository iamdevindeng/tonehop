import CoreAudio
import Foundation
import XCTest
@testable import ToneHop

/// Runs the production selection unit with value-only HAL observations and the
/// actual shutdown/epoch gate. No test registers or writes to a system device.
final class CoreAudioOutputSelectionTests: XCTestCase {
    func testUnchangedTargetSubmitsExactlyOneWrite() throws {
        let io = OutputSelectionFixture()
        try io.submit()
        XCTAssertEqual(io.writes, [1])
    }

    func testUIDChangedDuringInitialCapabilityReadNeverEntersSubmission() {
        let io = OutputSelectionFixture()
        io.onAvailability = { $0.devices[1]?.uid = "replacement" }
        XCTAssertThrowsError(try io.submit())
        XCTAssertTrue(io.writes.isEmpty)
        XCTAssertEqual(io.admissions, 0)
    }

    func testUIDChangedDuringSettableReadNeverWritesReplacement() {
        let io = OutputSelectionFixture()
        io.onSettable = { $0.devices[1]?.uid = "replacement" }
        XCTAssertThrowsError(try io.submit())
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testSameUIDOnReplacementObjectRequiresANewRequest() {
        let io = OutputSelectionFixture()
        io.onGate = { value in value.devices = [2: .init(uid: "target")] }
        XCTAssertThrowsError(try io.submit())
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testTargetBecomingUnavailableInsideGateNeverWrites() {
        let io = OutputSelectionFixture()
        io.onGate = { $0.devices[1]?.alive = false }
        XCTAssertThrowsError(try io.submit())
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testTargetLosingDefaultOutputEligibilityInsideGateNeverWrites() {
        let io = OutputSelectionFixture()
        io.onGate = { $0.devices[1]?.eligible = false }
        XCTAssertThrowsError(try io.submit())
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testFinalUIDReadRejectsChangeDuringFinalCapabilityRead() {
        let io = OutputSelectionFixture()
        io.onGate = { value in value.onAvailability = { $0.devices[1]?.uid = "replacement" } }
        XCTAssertThrowsError(try io.submit())
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testDuplicateUIDIntroducedBeforeSubmissionIsRejected() {
        let io = OutputSelectionFixture()
        io.onGate = { $0.devices[2] = .init(uid: "target") }
        XCTAssertThrowsError(try io.submit()) { error in
            guard case AudioServiceError.ambiguousIdentity = error else {
                return XCTFail("Expected ambiguous identity, received \(error)")
            }
        }
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testClosedShutdownGateRejectsPreparedSelection() {
        let io = OutputSelectionFixture()
        let signal = AudioShutdownSignal()
        io.onGate = { _ in signal.begin() }
        XCTAssertThrowsError(try io.submit(signal: signal)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testRevokedServiceLeaseRejectsPreparedSelection() {
        let io = OutputSelectionFixture()
        let epoch = AudioServiceEpoch()
        let lease = epoch.capture()
        io.onGate = { _ in epoch.reset(ifCurrent: lease.id) }
        XCTAssertThrowsError(try io.submit(lease: lease)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testCapabilityReadFailureDoesNotReachSetter() {
        let io = OutputSelectionFixture()
        io.onGate = { $0.availabilityError = .readFailed }
        XCTAssertThrowsError(try io.submit()) { XCTAssertEqual($0 as? OutputSelectionFixture.Failure, .readFailed) }
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testSetterFailureIsReturnedWithoutRetryOrRollback() {
        let io = OutputSelectionFixture()
        io.writeError = .writeFailed
        XCTAssertThrowsError(try io.submit()) { XCTAssertEqual($0 as? OutputSelectionFixture.Failure, .writeFailed) }
        XCTAssertEqual(io.writes, [1], "A failed setter can still have taken effect; never replay or undo it here.")
    }
}

private final class OutputSelectionFixture {
    enum Failure: Error, Equatable { case readFailed, writeFailed }
    struct Device {
        var uid: String
        var eligible = true
        var alive = true
    }

    var devices: [AudioObjectID: Device] = [1: .init(uid: "target")]
    var writes: [AudioObjectID] = []
    var admissions = 0
    var availabilityError: Failure?
    var writeError: Failure?
    var onAvailability: ((OutputSelectionFixture) -> Void)?
    var onSettable: ((OutputSelectionFixture) -> Void)?
    var onGate: ((OutputSelectionFixture) -> Void)?

    func submit(signal: AudioShutdownSignal = AudioShutdownSignal(), lease: AudioServiceEpoch.Lease? = nil) throws {
        try CoreAudioOutputSelection.submit(uid: "target",
            deviceIDs: { self.devices.keys.sorted() },
            readUID: { object in
                guard let uid = self.devices[object]?.uid else { throw AudioServiceError.targetMissing }
                return uid
            }, readAvailability: { object in
                self.onAvailability?(self)
                if let error = self.availabilityError { throw error }
                guard let device = self.devices[object] else { throw AudioServiceError.targetMissing }
                return (device.eligible, device.alive)
            }, checkSettable: { self.onSettable?(self) },
            checkRunning: { try signal.checkRunning(); try lease?.check() },
            performIfRunning: { operation in
                self.admissions += 1
                self.onGate?(self)
                return signal.performIfRunning(servicePermit: lease?.permit, operation)
            }, write: { object in
                self.writes.append(object)
                if let error = self.writeError { throw error }
            })
    }
}
