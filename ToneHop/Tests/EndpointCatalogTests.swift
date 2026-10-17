import XCTest
@testable import ToneHop

final class EndpointCatalogTests: XCTestCase {
    func testRemoteControlRepresentationDoesNotHideAudioReceiver() {
        let audio = row(id: "receiver", name: "Bedroom")
        var control = audio
        control["isRemoteControlOnly"] = true
        control["deviceFeatures"] = 0
        let result = EndpointCatalog.routes(from: [audio, control])
        XCTAssertEqual(result.routes.map(\.name), ["Bedroom"])
        XCTAssertNil(result.warning)
    }

    func testActiveEndpointAndLeafStreamDoNotProveSystemSelection() {
        var active = row(id: "receiver", name: "Bedroom")
        active["isActivated"] = true
        active["isConnected"] = true
        active["streamUIDs"] = ["leaf-stream-not-hal-uid"]
        let route = EndpointCatalog.routes(from: [active]).routes.first
        XCTAssertNotNil(route)
        XCTAssertNil(route?.uid)
        XCTAssertEqual(route?.isSelected, false)
        XCTAssertEqual(route?.canSelect, false)
    }

    func testConflictingAudioIdentitiesAreNotChosenByOrder() {
        let result = EndpointCatalog.routes(from: [row(id: "same", name: "Bedroom"),
                                                   row(id: "same", name: "Other")])
        XCTAssertTrue(result.routes.isEmpty)
        XCTAssertNotNil(result.warning)
    }

    func testCachedOrUnknownCapabilitiesAreNotLiveAudioTargets() {
        var cached = row(id: "cached", name: "Cached")
        cached["wrapperIsCached"] = true
        var unknown = row(id: "unknown", name: "Unknown")
        unknown.removeValue(forKey: "deviceFeatures")
        XCTAssertTrue(EndpointCatalog.routes(from: [cached, unknown]).routes.isEmpty)
    }

    private func row(id: String, name: String) -> [String: Any] {
        ["identifier": id, "name": name, "deviceFeatures": 1,
         "isRemoteControlOnly": false, "wrapperIsCached": false]
    }
}
