import Foundation

struct AudioCatalog {
    let devices: [AudioDevice]
    let currentDeviceID: String?
    let warning: String?

    /// A shared UID associates a receiver with its current HAL transport, not
    /// with a second selectable device. Keep the receiver's stable identity and
    /// routing capability; HAL writability does not prove private-route support.
    /// Names, apparent uniqueness on this network, and UUID prefixes are not identity.
    static func merge(hal: CoreAudioSnapshot, routes: PrivateRouteSnapshot) -> AudioCatalog {
        let discovery = AudioDiscoveryInventory.merge(hal: hal, routes: routes)
        var devices = hal.devices.map { device in
            guard device.transport == .airplay else { return device }
            // A writable transport is not a usable receiver reference. Keep
            // its identity and actual selection visible while discovery settles,
            // but never expose HAL as a bypass around private-route validation.
            var unidentified = device
            unidentified.isAvailable = false
            unidentified.unavailableReason = String(localized: "audio.confirm_airplay_receiver", defaultValue: "Confirming the AirPlay receiver. Select the device in the macOS Sound menu.")
            return unidentified
        }
        var selectedID = hal.currentDeviceID
        var warnings: [String] = []
        var privateSelection: [PrivateAudioRoute] = []
        var associatedHALIDs: [String: String] = [:]
        let visibleRoutes = routes.routes.filter { discovery.presence(of: .receiver(identifier: $0.identifier)) != .missing }
        let grouped = Dictionary(grouping: visibleRoutes, by: \.identifier)
        let uidOwners = Dictionary(grouping: routes.routes.filter { $0.uid?.isEmpty == false }, by: { $0.uid! })
        let ambiguousUIDs = Set(uidOwners.filter { Set($0.value.map(\.identifier)).count > 1 }.keys)
        for (identifier, matches) in grouped.sorted(by: { $0.key < $1.key }) {
            guard !identifier.isEmpty, matches.count == 1, let route = matches.first else {
                warnings.append(String(localized: "audio.network_identity_ambiguous", defaultValue: "Some network devices cannot be identified and are temporarily unavailable."))
                continue
            }
            if let uid = route.uid, ambiguousUIDs.contains(uid) {
                warnings.append(String(localized: "audio.multiple_network_targets", defaultValue: "Multiple network targets match the same system device. Their identities are not yet confirmed."))
                continue
            }
            let peers = devices.indices.filter { index in
                guard let uid = route.uid, !uid.isEmpty,
                      case let .coreAudio(halUID) = devices[index].backend else { return false }
                return uid == halUID
            }
            let id = "route:\(identifier)"
            let confirmedDiscovery = discovery.presence(of: .receiver(identifier: identifier)) == .found
            let canSelect = route.canSelect && confirmedDiscovery
            let routeDevice = AudioDevice(id: id, name: route.name,
                                          transport: AudioTransport(rawValue: route.transport) ?? .airplay,
                                          backend: .privateRoute(identifier: identifier),
                                          isAvailable: canSelect,
                                          unavailableReason: !confirmedDiscovery ? String(localized: "audio.confirm_device_status", defaultValue: "Confirming device status…")
                                              : (canSelect ? nil : (route.unavailableReason ?? String(localized: "audio.network_switch_unavailable", defaultValue: "This network device cannot be selected right now."))),
                                          shortcutTarget: confirmedDiscovery && routes.confirmedShortcutIdentifiers.contains(identifier)
                                              ? .receiver(identifier: identifier) : nil,
                                          icon: route.icon)
            if peers.count == 1, let index = peers.first {
                let original = devices[index]
                associatedHALIDs[id] = original.id
                devices[index] = routeDevice
            } else {
                devices.append(routeDevice)
                if peers.count > 1 {
                    warnings.append(String(localized: "audio.multiple_system_devices", defaultValue: "Multiple system devices match the same network target. Their identities are not yet confirmed."))
                }
            }
            if route.isSelected { privateSelection.append(route) }
        }
        if privateSelection.count == 1 {
            let route = privateSelection[0]
            let routeID = "route:\(route.identifier)"
            // A selected receiver must also match the exact default HAL UID.
            // A transport classification cannot identify which receiver owns it.
            let associatedDefault = hal.currentDeviceID != nil && associatedHALIDs[routeID] == hal.currentDeviceID
            if associatedDefault {
                selectedID = routeID
            } else {
                selectedID = nil
                warnings.append(String(localized: "audio.output_not_aligned", defaultValue: "The network route and system output do not yet match. The current output is not confirmed."))
            }
        }
        else if privateSelection.count > 1 {
            selectedID = nil
            warnings.append(String(localized: "audio.multiple_selected_routes", defaultValue: "The system reports multiple selected routes. The current output is not confirmed."))
        }
        // A matched transport can disappear from the list while its receiver
        // lacks system-selected evidence. HAL alone must not select that row.
        if let current = selectedID, !devices.contains(where: { $0.id == current }) {
            selectedID = nil
            warnings.append(String(localized: "audio.output_not_aligned", defaultValue: "The network route and system output do not yet match. The current output is not confirmed."))
        }
        if hal.devices.contains(where: { $0.transport == .airplay && $0.name == "AirPlay" }), routes.routes.isEmpty {
            warnings.append(String(localized: "audio.receiver_name_unconfirmed", defaultValue: "The receiver name for the current AirPlay route is not yet confirmed."))
        }
        let rank: [AudioTransport: Int] = [.speaker: 0, .display: 1, .usb: 2, .bluetooth: 3, .virtual: 4, .airplay: 5, .unknown: 6]
        devices.sort {
            let lhs = rank[$0.transport, default: 6], rhs = rank[$1.transport, default: 6]
            if lhs != rhs { return lhs < rhs }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
        return AudioCatalog(devices: devices, currentDeviceID: selectedID,
                            warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
    }

    /// A failed or incomplete source read does not turn an earlier row into a
    /// missing record. Keep its display identity, but discard all capabilities.
    func preservingUnconfirmedDevices(from previous: [AudioDevice], discovery: AudioDiscoveryInventory) -> AudioCatalog {
        var result = devices
        for device in previous {
            guard !result.contains(where: { $0.id == device.id }),
                  let identity = device.representedIdentity,
                  discovery.presence(of: identity) != .missing else { continue }
            // Fresh HAL AirPlay rows already participate in exact receiver
            // association above; retaining an old transport would duplicate it.
            if device.transport == .airplay, case .coreAudio = device.backend { continue }
            var pending = device
            pending.isAvailable = false
            pending.unavailableReason = String(localized: "audio.confirm_device_status", defaultValue: "Confirming device status…")
            pending.shortcutTarget = nil
            result.append(pending)
        }
        return AudioCatalog(devices: result, currentDeviceID: currentDeviceID, warning: warning)
    }
}
