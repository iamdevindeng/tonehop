import CoreAudio
import IOKit.audio
import XCTest
@testable import ToneHop

final class AudioDeviceIconTests: XCTestCase {
    @MainActor
    func testBothSurfacesUseRenderableSystemSymbolOrSpeakerFallback() {
        XCTAssertEqual(DeviceIconRendering.symbolName(for: .systemSymbol("homepodmini.fill")), "homepodmini.fill")
        XCTAssertEqual(DeviceIconRendering.symbolName(for: .systemSymbol("invalid-r08-symbol-fixture")),
                       AudioDeviceIcon.fallback.symbolName)
        XCTAssertEqual(DeviceIconRendering.symbolName(for: .fallback), AudioDeviceIcon.fallback.symbolName)
    }

    func testNamesAndTransportsDoNotManufactureModelGraphics() {
        for transport in [AudioTransport.speaker, .display, .bluetooth, .usb, .airplay, .virtual, .unknown] {
            let device = AudioDevice(id: "fixture", name: "HomePod mini Mac mini Headphones",
                                     transport: transport, backend: .unavailable)
            XCTAssertEqual(device.icon, .fallback)
        }
    }

    func testHostModelSymbolRequiresVerifiedBuiltInSpeaker() {
        for verified in [false, true] {
            let icon = CoreAudioDeviceIcon.resolve(modelIdentifier: nil, modelSymbol: nil,
                verifiedBuiltInSpeaker: verified, hostModelIdentifier: "fixture-host-model",
                hostModelSymbol: "macmini.gen2.fill", terminalTypes: [], imageFileURL: nil)
            XCTAssertEqual(icon.symbolName, verified ? "macmini.gen2.fill" : AudioDeviceIcon.fallback.symbolName)
            XCTAssertEqual(icon.source, verified ? .systemSymbol : .fallback)
        }
    }

    func testDriverImageURLRemainsEvidenceWithoutInventingMonochromeGraphic() {
        let url = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Fixture.driver/Contents/Resources/AppIcon.icns")
        let icon = CoreAudioDeviceIcon.resolve(modelIdentifier: "fixture-model", modelSymbol: nil,
            verifiedBuiltInSpeaker: false, hostModelIdentifier: nil, hostModelSymbol: nil,
            terminalTypes: [kAudioStreamTerminalTypeUnknown], imageFileURL: url)
        XCTAssertEqual(icon.symbolName, AudioDeviceIcon.fallback.symbolName)
        XCTAssertEqual(icon.source, .fallback)
        XCTAssertEqual(icon.imageFileURL, url)
        XCTAssertEqual(icon.modelIdentifier, "fixture-model")
    }

    func testTerminalMetadataSupportsGenericGraphicAndRejectsMixedOrUnknownTerminals() {
        let cases: [([UInt32], String, AudioDeviceIcon.Source)] = [
            ([kAudioStreamTerminalTypeHDMI], "display", .outputTerminal),
            ([kAudioStreamTerminalTypeDisplayPort], "display", .outputTerminal),
            ([UInt32(OUTPUT_HEADPHONES)], "headphones", .outputTerminal),
            ([UInt32(OUTPUT_SPEAKER)], "speaker.wave.2.fill", .outputTerminal),
            ([kAudioStreamTerminalTypeSpeaker, kAudioStreamTerminalTypeHeadphones], "speaker.wave.2.fill", .fallback),
            ([kAudioStreamTerminalTypeUnknown], "speaker.wave.2.fill", .fallback),
            ([], "speaker.wave.2.fill", .fallback),
        ]
        for (terminals, symbol, source) in cases {
            let icon = CoreAudioDeviceIcon.resolve(modelIdentifier: nil, modelSymbol: nil,
                verifiedBuiltInSpeaker: false, hostModelIdentifier: nil, hostModelSymbol: nil,
                terminalTypes: terminals, imageFileURL: nil)
            XCTAssertEqual(icon.symbolName, symbol)
            XCTAssertEqual(icon.source, source)
        }
    }

    @MainActor
    func testConfirmedDisplayConnectionSuppliesSharedGenericGlyphForUnspecifiedTerminal() {
        for transport in [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort] {
            for terminals in [[], [kAudioStreamTerminalTypeUnknown]] {
                let icon = CoreAudioDeviceIcon.resolve(modelIdentifier: nil, modelSymbol: nil,
                    verifiedBuiltInSpeaker: false, hostModelIdentifier: nil, hostModelSymbol: nil,
                    terminalTypes: terminals, imageFileURL: nil, confirmedTransportType: transport)
                XCTAssertEqual(icon.symbolName, "display")
                XCTAssertEqual(icon.source, .displayConnection)
                XCTAssertNil(icon.modelIdentifier, "A connection graphic must not invent a display model.")
                XCTAssertEqual(DeviceIconRendering.symbolName(for: icon), "display")
            }
        }
    }

    func testOtherOrUnconfirmedConnectionsDoNotGuessDeviceGraphics() {
        let transports: [UInt32?] = [nil, kAudioDeviceTransportTypeUnknown, kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate]
        for transport in transports {
            let icon = CoreAudioDeviceIcon.resolve(modelIdentifier: nil, modelSymbol: nil,
                verifiedBuiltInSpeaker: false, hostModelIdentifier: nil, hostModelSymbol: nil,
                terminalTypes: [kAudioStreamTerminalTypeUnknown], imageFileURL: nil,
                confirmedTransportType: transport)
            XCTAssertEqual(icon, .fallback)
        }
    }

    func testDisplayConnectionDoesNotOverrideModelOrKnownTerminalEvidence() {
        let model = CoreAudioDeviceIcon.resolve(modelIdentifier: "fixture-model", modelSymbol: "appletv.fill",
            verifiedBuiltInSpeaker: false, hostModelIdentifier: nil, hostModelSymbol: nil,
            terminalTypes: [kAudioStreamTerminalTypeUnknown], imageFileURL: nil,
            confirmedTransportType: kAudioDeviceTransportTypeHDMI)
        XCTAssertEqual(model.symbolName, "appletv.fill")
        XCTAssertEqual(model.source, .systemSymbol)
        XCTAssertEqual(model.modelIdentifier, "fixture-model")

        let cases: [([UInt32], String, AudioDeviceIcon.Source)] = [
            ([kAudioStreamTerminalTypeHeadphones], "headphones", .outputTerminal),
            ([kAudioStreamTerminalTypeSpeaker], "speaker.wave.2.fill", .outputTerminal),
            ([kAudioStreamTerminalTypeSpeaker, kAudioStreamTerminalTypeHeadphones], "speaker.wave.2.fill", .fallback),
            ([kAudioStreamTerminalTypeUnknown, kAudioStreamTerminalTypeSpeaker], "speaker.wave.2.fill", .fallback),
        ]
        for (terminals, symbol, source) in cases {
            let icon = CoreAudioDeviceIcon.resolve(modelIdentifier: nil, modelSymbol: nil,
                verifiedBuiltInSpeaker: false, hostModelIdentifier: nil, hostModelSymbol: nil,
                terminalTypes: terminals, imageFileURL: nil,
                confirmedTransportType: kAudioDeviceTransportTypeHDMI)
            XCTAssertEqual(icon.symbolName, symbol)
            XCTAssertEqual(icon.source, source)
        }
    }

    func testDisplayConnectionGraphicDoesNotGrantAvailabilitySelectionOrShortcutIdentity() {
        let icon = CoreAudioDeviceIcon.resolve(modelIdentifier: nil, modelSymbol: nil,
            verifiedBuiltInSpeaker: false, hostModelIdentifier: nil, hostModelSymbol: nil,
            terminalTypes: [kAudioStreamTerminalTypeUnknown], imageFileURL: nil,
            confirmedTransportType: kAudioDeviceTransportTypeHDMI)
        let device = AudioDevice(id: "hal:fixture-display", name: "Same name", transport: .display,
            backend: .coreAudio(uid: "fixture-display"), isAvailable: false,
            unavailableReason: "Fixture identity unconfirmed", icon: icon)
        let hal = CoreAudioSnapshot(devices: [device], currentDeviceID: nil, systemSoundDeviceID: nil, warnings: [])
        let routes = PrivateRouteSnapshot(routes: [], warning: nil, diagnostics: "fixture")
        let result = AudioCatalog.merge(hal: hal, routes: routes)
        XCTAssertEqual(result.devices, [device])
        XCTAssertEqual(result.devices[0].icon.symbolName, "display")
        XCTAssertFalse(result.devices[0].isAvailable)
        XCTAssertNil(result.devices[0].shortcutTarget)
        XCTAssertNil(result.currentDeviceID)
        XCTAssertEqual(AudioDiscoveryInventory.merge(hal: hal, routes: routes)
            .presence(of: .hal(uid: "fixture-display")), .unconfirmed)
    }

    func testPrivateIconRequiresMatchingStableReceiverIdentity() {
        let valid = iconEvidence(identifier: "receiver-A", symbol: "homepodmini.fill")
        let variants: [[String: Any]] = [
            valid,
            valid.merging(["readbackIdentifier": "receiver-B"]) { _, value in value },
            valid.merging(["readbackStable": false]) { _, value in value },
            valid.merging(["readbackStable": 1]) { _, value in value },
            valid.merging(["symbolName": NSNull()]) { _, value in value },
        ]
        for (index, evidence) in variants.enumerated() {
            let av = PrivateRouteSnapshotAdapter.avDiscovery(["routes": [["identifier": "receiver-A",
                "name": "Bedroom", "transport": "airplay", "iconEvidence": evidence]]])
            XCTAssertEqual(av.routes[0].icon.symbolName, index == 0 ? "homepodmini.fill" : AudioDeviceIcon.fallback.symbolName)
            XCTAssertFalse(av.routes[0].canSelect)
            XCTAssertFalse(av.routes[0].isSelected)
            XCTAssertTrue(av.bindingIdentity.confirmed.isEmpty)
        }
    }

    func testConflictingGraphicsFallBackWithoutChangingRouteCapabilities() {
        let avRoute = route("receiver-A", symbol: "homepodmini.fill")
        let endpointRoute = route("receiver-A", symbol: "hifispeaker.fill")
        let result = merged(av: [avRoute], endpoints: [endpointRoute])
        XCTAssertEqual(result.routes[0].icon, .fallback)
        XCTAssertFalse(result.routes[0].canSelect)
        XCTAssertFalse(result.routes[0].isSelected)
    }

    func testRawIdentityConflictWithholdsGraphicEvenWhenSymbolsAgree() {
        var av = AVRouteDiscoveryEvidence(routes: [route("receiver-A", symbol: "homepodmini.fill")],
            elapsed: 0, issue: nil, diagnostics: "fixture", outcome: .succeeded)
        av.discovery = AudioDiscoverySourceInventory(conflictedIdentifiers: ["receiver-A"])
        let result = PrivateRouteCatalog.merge(av: av,
            endpoints: EndpointDiscoveryEvidence(routes: [], elapsed: 0, warning: nil, diagnostics: "fixture", outcome: .succeeded),
            selection: .failed(failure), retained: .failed(failure))
        XCTAssertEqual(result.routes[0].icon, .fallback)
    }

    func testSameNameDifferentReceiverIdentitiesKeepIndependentGraphics() {
        let result = merged(av: [route("receiver-A", symbol: "homepodmini.fill"), route("receiver-B", symbol: "appletv.fill")])
        XCTAssertEqual(result.routes.first { $0.identifier == "receiver-A" }?.icon.symbolName, "homepodmini.fill")
        XCTAssertEqual(result.routes.first { $0.identifier == "receiver-B" }?.icon.symbolName, "appletv.fill")
    }

    func testStrictSelectedRouteKeepsOnlyTheMatchingDiscoveredGraphic() {
        let selected = PrivateAudioRoute(identifier: "receiver-A", name: "System Bedroom", uid: "stream-A",
                                         isSelected: true, canSelect: false, transport: "airplay")
        let result = merged(av: [route("receiver-A", symbol: "homepodmini.fill"), route("receiver-B", symbol: "appletv.fill")],
                            selected: selected)
        XCTAssertEqual(result.routes.first { $0.isSelected }?.icon.symbolName, "homepodmini.fill")
        XCTAssertFalse(result.routes.first { $0.isSelected }!.canSelect)
    }

    func testExactHALAssociationProjectsReceiverGraphicWithoutHALCapabilityBypass() {
        let halDevice = AudioDevice(id: "hal:stream-A", name: "AirPlay", transport: .airplay,
                                    backend: .coreAudio(uid: "stream-A"), icon: .systemSymbol("appletv.fill"))
        let route = PrivateAudioRoute(identifier: "receiver-A", name: "Bedroom", uid: "stream-A",
            isSelected: true, canSelect: false, transport: "airplay", icon: .systemSymbol("homepodmini.fill"))
        let hal = CoreAudioSnapshot(devices: [halDevice], currentDeviceID: halDevice.id, systemSoundDeviceID: nil, warnings: [])
        let routes = PrivateRouteSnapshot(routes: [route], warning: nil, diagnostics: "fixture")
        let result = AudioCatalog.merge(hal: hal, routes: routes)
        XCTAssertEqual(result.devices[0].icon.symbolName, "homepodmini.fill")
        XCTAssertEqual(result.currentDeviceID, "route:receiver-A")
        XCTAssertFalse(result.devices[0].isAvailable)
        XCTAssertNil(result.devices[0].shortcutTarget)
    }

    private let failure = NSError(domain: "AudioDeviceIconFixture", code: 1)

    private func iconEvidence(identifier: String, symbol: String) -> [String: Any] {
        ["identifier": identifier, "readbackIdentifier": identifier,
         "readbackStable": true, "modelIdentifier": "fixture-model", "symbolName": symbol]
    }

    private func route(_ identifier: String, symbol: String) -> PrivateAudioRoute {
        PrivateAudioRoute(identifier: identifier, name: "Shared name", uid: nil, isSelected: false,
                          canSelect: false, transport: "airplay", icon: .systemSymbol(symbol))
    }

    private func merged(av: [PrivateAudioRoute], endpoints: [PrivateAudioRoute] = [], selected: PrivateAudioRoute? = nil) -> PrivateRouteSnapshot {
        PrivateRouteCatalog.merge(
            av: AVRouteDiscoveryEvidence(routes: av, elapsed: 0, issue: nil, diagnostics: "fixture", outcome: .succeeded),
            endpoints: EndpointDiscoveryEvidence(routes: endpoints, elapsed: 0, warning: nil, diagnostics: "fixture", outcome: .succeeded),
            selection: SystemSelectionEvidence(route: selected, diagnostics: "fixture", outcome: selected == nil ? .failed : .succeeded),
            retained: .failed(failure))
    }
}
