import Foundation
import XCTest
@testable import ToneHop

final class BuildInfoTests: XCTestCase {
    private func payload(overrides: [String: Any] = [:]) throws -> Data {
        var fields: [String: Any] = [
            "schemaVersion": 1, "applicationVersion": "0.1.0", "buildNumber": "2",
            "configuration": "Debug", "gitCommit": "unknown", "gitWorkingTreeState": "unknown",
            "sourceDigestAlgorithm": "sha256-manifest-v1", "sourceDigest": String(repeating: "a", count: 64),
            "sourceFileCount": 42,
        ]
        fields.merge(overrides) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: fields)
    }

    func testSourceArchiveCanHaveKnownDigestAndUnknownGitIdentity() throws {
        let info = try XCTUnwrap(BuildInfo.decode(payload()))
        XCTAssertEqual(info.gitCommit, "unknown")
        XCTAssertEqual(info.gitWorkingTreeState, "unknown")
        XCTAssertEqual(info.sourceDigest, String(repeating: "a", count: 64))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(info.diagnosticFields))
    }

    func testMissingMalformedAndUnsupportedResourcesDoNotInventIdentity() throws {
        XCTAssertNil(BuildInfo.decode(nil))
        XCTAssertNil(BuildInfo.decode(Data("broken".utf8)))
        for overrides: [String: Any] in [
            ["schemaVersion": 2], ["gitWorkingTreeState": "probably clean"],
            ["sourceDigest": "not a hash"], ["sourceFileCount": 0],
            ["sourceDigestAlgorithm": "unknown"],
        ] {
            XCTAssertNil(BuildInfo.decode(try payload(overrides: overrides)))
        }
        let fallback = BuildInfo.unknown(version: "0.1.0", buildNumber: "2")
        XCTAssertEqual(fallback.applicationVersion, "0.1.0")
        XCTAssertEqual(fallback.buildNumber, "2")
        XCTAssertEqual(fallback.gitCommit, "unknown")
        XCTAssertEqual(fallback.sourceDigest, "unknown")
    }
}
