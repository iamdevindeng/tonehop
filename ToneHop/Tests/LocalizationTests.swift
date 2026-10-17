import Foundation
import XCTest
@testable import ToneHop

final class LocalizationTests: XCTestCase {
    func testBothLanguagesShipCompleteNonemptyTablesWithMatchingFormatArguments() throws {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        XCTAssertTrue(Set(Bundle.main.localizations).isSuperset(of: ["en", "zh-Hans"]))
        let english = try strings(language: "en", table: "Localizable")
        let chinese = try strings(language: "zh-Hans", table: "Localizable")
        XCTAssertGreaterThan(english.count, 100, "The built app must contain the whole user-facing catalog.")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys), "Neither supported language may silently fall back for missing copy.")
        for key in english.keys.sorted() {
            let source = try XCTUnwrap(english[key])
            let translation = try XCTUnwrap(chinese[key], key)
            XCTAssertFalse(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            XCTAssertFalse(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            XCTAssertEqual(try formatArguments(source), try formatArguments(translation),
                           "Interpolation arguments must keep their type and position: \(key)")
        }
    }

    func testNetworkPermissionExplanationShipsInBothLanguages() throws {
        let english = try strings(language: "en", table: "InfoPlist")
        let chinese = try strings(language: "zh-Hans", table: "InfoPlist")
        let key = "NSLocalNetworkUsageDescription"
        let englishReason = try XCTUnwrap(english[key])
        let chineseReason = try XCTUnwrap(chinese[key])
        XCTAssertFalse(englishReason.isEmpty)
        XCTAssertFalse(chineseReason.isEmpty)
        XCTAssertNotEqual(englishReason, chineseReason)
        XCTAssertTrue(englishReason.contains("AirPlay"))
        XCTAssertTrue(chineseReason.contains("AirPlay"))
    }

    private func strings(language: String, table: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: language),
                                "Missing bundled \(language)/\(table).strings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private func formatArguments(_ text: String) throws -> [String] {
        let escapedPercentsRemoved = text.replacingOccurrences(of: "%%", with: "")
        let pattern = #"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDuUxXoOfFeEgGcCsSpaA])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let input = escapedPercentsRemoved as NSString
        return regex.matches(in: escapedPercentsRemoved, range: NSRange(location: 0, length: input.length))
            .enumerated().map { index, match in
                let position = match.range(at: 1).location == NSNotFound ? String(index + 1) : input.substring(with: match.range(at: 1))
                let length = match.range(at: 2).location == NSNotFound ? "" : input.substring(with: match.range(at: 2))
                return position + ":" + length + input.substring(with: match.range(at: 3))
            }.sorted()
    }
}
