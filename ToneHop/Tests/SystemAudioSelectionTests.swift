import XCTest
@testable import ToneHop

final class SystemAudioSelectionTests: XCTestCase {
    private var validEvidence: [String: Any] {
        ["identifier": "receiver-1", "name": "Living Room", "uid": "aggregate-stream-2",
         "aggregateIdentifier": "aggregate-1", "contextIdentifier": "system-context",
         "aggregateContextIdentifier": "system-context", "associatedUID": "aggregate-stream-2",
         "halUID": "aggregate-stream-2", "audioStreamUIDs": ["aggregate-stream-2"],
         "memberIdentifiers": ["receiver-1"], "readbackStable": true]
    }

    func testVerifiedSystemSelectionKeepsReceiverIdentityWithoutGrantingSwitching() {
        let route = SystemAudioSelection.route(from: ["selection": validEvidence])
        XCTAssertEqual(route?.identifier, "receiver-1")
        XCTAssertEqual(route?.name, "Living Room")
        XCTAssertEqual(route?.uid, "aggregate-stream-2")
        XCTAssertEqual(route?.isSelected, true)
        XCTAssertEqual(route?.canSelect, false)
    }

    func testStaleHALOrContextEvidenceDoesNotCreateSelection() {
        for key in ["halUID", "associatedUID", "aggregateContextIdentifier"] {
            var evidence = validEvidence
            evidence[key] = "previous-value"
            XCTAssertNil(SystemAudioSelection.route(from: ["selection": evidence]), key)
        }
        var evidence = validEvidence
        evidence["readbackStable"] = false
        XCTAssertNil(SystemAudioSelection.route(from: ["selection": evidence]))
    }

    func testMultipleMembersOrStreamsCannotBeCollapsedIntoOneReceiver() {
        var evidence = validEvidence
        evidence["memberIdentifiers"] = ["receiver-1", "receiver-2"]
        XCTAssertNil(SystemAudioSelection.route(from: ["selection": evidence]))
        evidence = validEvidence
        evidence["audioStreamUIDs"] = ["aggregate-stream-2", "aggregate-stream-3"]
        XCTAssertNil(SystemAudioSelection.route(from: ["selection": evidence]))
    }

    func testMissingOrMalformedEvidenceDoesNotInventSelection() {
        XCTAssertNil(SystemAudioSelection.route(from: ["selection": NSNull()]))
        for key in ["identifier", "name", "aggregateIdentifier", "contextIdentifier", "memberIdentifiers"] {
            var evidence = validEvidence
            evidence[key] = NSNull()
            XCTAssertNil(SystemAudioSelection.route(from: ["selection": evidence]), key)
        }
    }

    func testReadbackStableMustBeAnActualBoolean() {
        for value: Any in [NSNumber(value: 1), "true", NSNull()] {
            var evidence = validEvidence
            evidence["readbackStable"] = value
            XCTAssertNil(SystemAudioSelection.route(from: ["selection": evidence]))
        }
    }
}
