import XCTest
@testable import ToneHop

final class THOwnedAirPlayStreamTests: XCTestCase {
    private let first = "12345678-abcd-4abc-8def-123456789abc-123456789012345-Audio"
    private let replacement = "12345678-abcd-4abc-8def-123456789abc-123456789012346-Audio"

    func testExactWitnessedGenerationAllowsTheStreamIdentityCheck() {
        XCTAssertTrue(THOwnedAirPlayStreamMatches(first, first))
    }

    func testAnUnwitnessedLateAddCannotClaimTheSystemsCurrentStream() {
        XCTAssertFalse(THOwnedAirPlayStreamMatches(nil, first))
        XCTAssertFalse(THOwnedAirPlayStreamMatches("", first))
    }

    func testTheSameAggregateWithANewGenerationIsNotTheAppsStream() {
        XCTAssertFalse(THOwnedAirPlayStreamMatches(first, replacement))
        XCTAssertFalse(THOwnedAirPlayStreamMatches(first, first.uppercased()))
    }

    func testMissingLiveStreamIsNotEvidenceForRemovingAMember() {
        XCTAssertFalse(THOwnedAirPlayStreamMatches(first, nil))
        XCTAssertFalse(THOwnedAirPlayStreamMatches(first, ""))
        XCTAssertFalse(THOwnedAirPlayStreamMatches(nil, nil))
        XCTAssertFalse(THOwnedAirPlayStreamMatches("", ""))
    }
}
