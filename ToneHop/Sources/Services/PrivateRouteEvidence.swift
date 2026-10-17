import Foundation

/// Issued only from the strict SystemAudio selected aggregate/stream/HAL readback.
/// Directory-only UID associations cannot construct this capability implicitly.
struct SystemRouteVolumeAssociation: Equatable, Sendable {
    let identifier: String
    let uid: String
}

struct RouteBindingIdentityEvidence: Equatable, Sendable {
    var confirmed: Set<String> = []
    var conflicted: Set<String> = []
}

/// Presentation classification and write capability are separate facts. Preserve
/// unrecognized classifications at the boundary rather than treating them as AirPlay.
enum PrivateRouteTransport: Sendable, Equatable {
    case airplay
    case other(String)

    init(rawValue: String) {
        self = rawValue == "airplay" ? .airplay : .other(rawValue)
    }

    var rawValue: String {
        switch self {
        case .airplay: "airplay"
        case let .other(value): value
        }
    }
}

enum PrivateRouteSelectionCapability: Sendable, Equatable {
    case unavailable
    case retainedAirPlay
    case existingSystemStream
    case avSystemRoute
}

/// A distinct, freshly checked permission to recover an uncaptured system
/// stream through the normal retained bridge. This carries no ownership,
/// selected-output claim, or volume authorization.
struct ExistingSystemStreamRecovery: Sendable, Equatable {
    let identifier: String
    let name: String
    let uid: String
    let aggregateIdentifier: String
    let contextIdentifier: String
}

/// A successful bridge call does not imply that it supplied valid identity or
/// capability evidence. Failed reads never inherit the preceding read's values.
enum PrivateRouteReadOutcome: Sendable, Equatable {
    case succeeded
    case partial
    case failed
}

/// Source failures remain observable after composition. An empty successful
/// discovery and a failed discovery are different states, even with no rows.
struct PrivateRouteSourceHealth: Sendable, Equatable {
    let avDiscovery: PrivateRouteReadOutcome
    let endpointDiscovery: PrivateRouteReadOutcome
    let systemSelection: PrivateRouteReadOutcome
    let retainedRoute: PrivateRouteReadOutcome

    var warning: String? {
        let sources: [(PrivateRouteReadOutcome, String)] = [
            (avDiscovery, String(localized: "service.network_discovery", defaultValue: "network device discovery")), (endpointDiscovery, String(localized: "service.receiver_discovery", defaultValue: "receiver discovery")),
            (systemSelection, String(localized: "service.current_receiver", defaultValue: "current receiver confirmation")), (retainedRoute, String(localized: "service.receiver_capability", defaultValue: "receiver switching capability")),
        ]
        let failed = sources.filter { $0.0 == .failed }.map(\.1)
        if failed.count == sources.count {
            return String(localized: "audio.network_status_failed", defaultValue: "Network audio status could not be read. The AirPlay device list and current receiver cannot be confirmed.")
        }
        var warnings: [String] = []
        if !failed.isEmpty {
            warnings.append(String(localized: "audio.network_status_partial_failure", defaultValue: "Some network audio status could not be read (\(failed.joined(separator: String(localized: "service.list_separator", defaultValue: ", ")))). Related device information or capabilities may be incomplete."))
        }
        let partial = sources.filter { $0.0 == .partial }.map(\.1)
        if !partial.isEmpty {
            warnings.append(String(localized: "audio.network_status_incomplete", defaultValue: "Some network audio information is incomplete (\(partial.joined(separator: String(localized: "service.list_separator", defaultValue: ", ")))). Devices with confirmed information are still listed."))
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }
}

/// Only the bridge's declared application errors control retry policy. Keep
/// the original NSError unchanged for user feedback and OSStatus diagnostics.
enum RetainedRouteFailure: Sendable, Equatable {
    case pending
    case blocked
    case failed

    init(_ error: any Error) {
        let failure = error as NSError
        guard failure.domain == THRetainedAudioErrorDomain else {
            self = .failed
            return
        }
        switch failure.code {
        case THRetainedAudioError.pending.rawValue: self = .pending
        case THRetainedAudioError.cleanupBlocked.rawValue: self = .blocked
        default: self = .failed
        }
    }
}

/// Native dictionaries distinguish a verified empty value from missing or
/// malformed evidence. In particular, only explicit null can prove an empty UID.
enum RouteStringEvidence: Sendable, Equatable {
    case missing
    case null
    case value(String)
    case malformed

    init(_ value: Any?) {
        switch value {
        case nil: self = .missing
        case is NSNull: self = .null
        case let value as String: self = .value(value)
        default: self = .malformed
        }
    }

    var string: String? {
        guard case let .value(value) = self else { return nil }
        return value
    }
}

enum PrivateDeviceEligibility: Sendable, Equatable {
    case eligible
    case blocked
    case unknown
}

struct AVRouteSelectionEvidence: Sendable, Equatable {
    let canSelect: Bool?
    let isSelected: Bool?
    let contextWritable: Bool?
    let identityUnique: Bool?
    let deviceEligibility: PrivateDeviceEligibility
    let uidEvidence: RouteStringEvidence

    var lacksOnlyWritableContext: Bool {
        canSelect == false && isSelected == false && contextWritable == false && identityUnique == true &&
            deviceEligibility == .eligible && uidEvidence != .malformed
    }
}

struct EndpointAVIdentityEvidence: Sendable, Equatable {
    let endpointIdentifier: String
    let avDeviceIdentifier: String
    let readbackStable: Bool?
    let deviceEligibility: PrivateDeviceEligibility

    func confirms(_ identifier: String) -> Bool {
        endpointIdentifier == identifier && avDeviceIdentifier == identifier &&
            readbackStable == true && deviceEligibility == .eligible
    }
}

struct AVRouteDiscoveryEvidence: Sendable, Equatable {
    let routes: [PrivateAudioRoute]
    let elapsed: Double
    let issue: String?
    let diagnostics: String
    let outcome: PrivateRouteReadOutcome
    var selectionEvidence: [String: AVRouteSelectionEvidence] = [:]
    var bindingIdentity = RouteBindingIdentityEvidence()
    var discovery: AudioDiscoverySourceInventory = .unconfirmed

    static func failed(_ error: any Error) -> Self {
        Self(routes: [], elapsed: 0, issue: error.localizedDescription,
             diagnostics: "AVRouting error: \(error)", outcome: .failed)
    }
}

struct EndpointDiscoveryEvidence: Sendable, Equatable {
    let routes: [PrivateAudioRoute]
    let elapsed: Double
    let warning: String?
    let diagnostics: String
    let outcome: PrivateRouteReadOutcome
    var avIdentityEvidence: [String: EndpointAVIdentityEvidence] = [:]
    var bindingIdentity = RouteBindingIdentityEvidence()
    var discovery: AudioDiscoverySourceInventory = .unconfirmed

    static func failed(_ error: any Error) -> Self {
        Self(routes: [], elapsed: 0, warning: nil,
             diagnostics: "FigEndpointManager error: \(error)", outcome: .failed)
    }
}

struct SystemSelectionEvidence: Sendable, Equatable {
    let route: PrivateAudioRoute?
    let diagnostics: String
    let outcome: PrivateRouteReadOutcome
    var confirmsUnselectedAggregate = false

    static func failed(_ error: any Error) -> Self {
        Self(route: nil, diagnostics: "SystemAudio error: \(error)", outcome: .failed)
    }
}

struct RetainedSystemRouteEvidence: Sendable, Equatable {
    let capability: RetainedRouteCapability?
    let existingStreamAssociation: ExistingSystemStreamAssociation?
    let memberComparison: SystemRouteMemberComparison?
    let diagnostics: String
    let outcome: PrivateRouteReadOutcome
    var verifiedUnselectedDescriptor: PrivateAudioRoute? = nil
    var existingStreamRecovery: ExistingSystemStreamRecovery? = nil

    static func failed(_ error: any Error) -> Self {
        Self(capability: nil, existingStreamAssociation: nil, memberComparison: nil,
             diagnostics: "RetainedSystemAudio error: \(error)", outcome: .failed)
    }
}

/// The only dictionary-decoding boundary for the private route catalog. Invoke
/// it beside the bridge on the audio executor; only Sendable values leave it.
/// Discovery claims are not selected-output evidence. Supplemental authorization
/// facts remain strict and cannot be inferred from missing or malformed data.
enum PrivateRouteSnapshotAdapter {
    static func avDiscovery(_ raw: [String: Any]) -> AVRouteDiscoveryEvidence {
        let rows = raw["routes"] as? [[String: Any]] ?? []
        let routes = rows.compactMap { row -> PrivateAudioRoute? in
            guard let identifier = row["identifier"] as? String,
                  let name = row["name"] as? String else { return nil }
            return PrivateAudioRoute(identifier: identifier, name: name, uid: row["uid"] as? String,
                                     isSelected: false,
                                     canSelect: row["canSelect"] as? Bool ?? false,
                                     transport: row["transport"] as? String ?? "unknown",
                                     icon: routeIcon(row, identifier: identifier))
        }
        var evidenceByID: [String: AVRouteSelectionEvidence] = [:]
        let groups = Dictionary(grouping: rows.filter { nonempty($0["identifier"]) != nil }) { $0["identifier"] as! String }
        for (identifier, matches) in groups where matches.count == 1 {
            let evidence = matches[0]["selectionEvidence"] as? [String: Any]
            evidenceByID[identifier] = AVRouteSelectionEvidence(canSelect: strictBoolean(matches[0]["canSelect"]),
                isSelected: strictBoolean(matches[0]["isSelected"]), contextWritable: strictBoolean(evidence?["contextWritable"]),
                identityUnique: strictBoolean(evidence?["identityUnique"]),
                deviceEligibility: deviceEligibility(evidence?["deviceEligibility"]),
                uidEvidence: RouteStringEvidence(matches[0]["uid"]))
        }
        var binding = bindingIdentities(rows, displayed: routes)
        for identifier in Array(binding.confirmed) {
            guard evidenceByID[identifier]?.identityUnique == true else {
                binding.confirmed.remove(identifier)
                if evidenceByID[identifier]?.identityUnique == false { binding.conflicted.insert(identifier) }
                continue
            }
        }
        return AVRouteDiscoveryEvidence(routes: routes, elapsed: raw["elapsed"] as? Double ?? 0,
                                        issue: raw["issue"] as? String,
                                        diagnostics: raw["diagnostics"] as? String ?? "AVRouting: no diagnostics",
                                        outcome: .succeeded, selectionEvidence: evidenceByID,
                                        bindingIdentity: binding,
                                        discovery: avDiscoveryInventory(raw))
    }

    static func endpointDiscovery(_ raw: [String: Any]) -> EndpointDiscoveryEvidence {
        let rawRows = raw["endpoints"] as? [[String: Any]]
        let rows = rawRows ?? []
        let catalog = endpointRoutes(rows)
        // Native producers count only missing/failed fields needed to identify
        // and qualify a row; optional diagnostic properties do not degrade it.
        // Unknown completeness never erases the healthy rows that were decoded.
        let incompleteCount = nonnegativeCount(raw["incompleteDeviceCount"])
        let outcome: PrivateRouteReadOutcome = rawRows == nil ? .failed : incompleteCount == 0 ? .succeeded : .partial
        // Supplemental selection capability still requires a unique raw row,
        // even when another row is filtered from display. The companion-pair
        // exception below applies only to persistent binding identity.
        let groups = Dictionary(grouping: rows.filter { nonempty($0["identifier"]) != nil }) { $0["identifier"] as! String }
        let displayedIDs = Set(catalog.routes.map(\.identifier))
        var identities: [String: EndpointAVIdentityEvidence] = [:]
        for (identifier, matches) in groups where matches.count == 1 && displayedIDs.contains(identifier) {
            let row = matches[0]
            guard let identity = row["avIdentity"] as? [String: Any],
                  let endpointID = nonempty(identity["endpointIdentifier"]),
                  let avID = nonempty(identity["avDeviceIdentifier"]) else { continue }
            identities[identifier] = EndpointAVIdentityEvidence(endpointIdentifier: endpointID, avDeviceIdentifier: avID,
                readbackStable: strictBoolean(identity["readbackStable"]), deviceEligibility: endpointDeviceEligibility(row))
        }
        let binding = endpointBindingIdentities(rows, displayed: catalog.routes)
        // Explicitly cached endpoints are remembered records, not current
        // discovery. Unknown cache/identity evidence blocks absence instead of
        // silently dropping a receiver that may still be present.
        let liveRows = rows.filter { strictBoolean($0["wrapperIsCached"]) != true && strictBoolean($0["isCached"]) != true }
        let observed = Set(liveRows.compactMap { nonempty($0["identifier"]) })
        let identityComplete = rows.allSatisfy { row in
            guard let identifier = nonempty(row["identifier"]),
                  let identity = row["discoveryIdentity"] as? [String: Any],
                  identity["identifier"] as? String == identifier,
                  identity["readbackIdentifier"] as? String == identifier,
                  strictBoolean(identity["readbackStable"]) == true else { return false }
            return true
        }
        let discovery = AudioDiscoverySourceInventory(observedIdentifiers: observed,
            conflictedIdentifiers: binding.conflicted,
            isComplete: outcome == .succeeded && identityComplete
                && nonnegativeCount(raw["endpointCount"]) == rows.count)
        return EndpointDiscoveryEvidence(routes: catalog.routes, elapsed: raw["elapsed"] as? Double ?? 0,
                                         warning: catalog.warning,
                                         diagnostics: "FigEndpointManager: \(raw["diagnostics"] ?? "unavailable")",
                                         outcome: outcome, avIdentityEvidence: identities,
                                         bindingIdentity: binding, discovery: discovery)
    }

    private static func avDiscoveryInventory(_ raw: [String: Any]) -> AudioDiscoverySourceInventory {
        guard let evidence = raw["discoveryIdentity"] as? [String: Any],
              let identifiers = evidence["identifiers"] as? [String],
              let declaredConflicts = evidence["conflictedIdentifiers"] as? [String] else { return .unconfirmed }
        let groups = Dictionary(grouping: identifiers, by: { $0 })
        let conflicts = Set(declaredConflicts).union(groups.filter { $0.value.count > 1 }.keys)
        return AudioDiscoverySourceInventory(observedIdentifiers: Set(identifiers.filter { !$0.isEmpty }),
            conflictedIdentifiers: conflicts,
            isComplete: strictBoolean(evidence["isComplete"]) == true && identifiers.allSatisfy { !$0.isEmpty })
    }

    private static func bindingIdentities(_ rawRows: [[String: Any]], displayed: [PrivateAudioRoute]) -> RouteBindingIdentityEvidence {
        let groups = Dictionary(grouping: rawRows.compactMap { nonempty($0["identifier"]) }, by: { $0 })
        let conflicts = Set(groups.filter { $0.value.count != 1 }.keys)
        let complete = rawRows.allSatisfy { nonempty($0["identifier"]) != nil }
        let visible = Set(displayed.map(\.identifier))
        let unique = complete ? Set(groups.filter { $0.value.count == 1 }.keys).intersection(visible) : []
        return RouteBindingIdentityEvidence(confirmed: unique, conflicted: conflicts)
    }

    private static func endpointBindingIdentities(_ rawRows: [[String: Any]],
                                                  displayed: [PrivateAudioRoute]) -> RouteBindingIdentityEvidence {
        var binding = bindingIdentities(rawRows, displayed: displayed)
        guard rawRows.allSatisfy({ nonempty($0["identifier"]) != nil }) else { return binding }
        let groups = Dictionary(grouping: rawRows) { $0["identifier"] as! String }
        for (identifier, rows) in groups where rows.count == 2 {
            // The native catalog can contain an audio endpoint and its separate
            // remote-control companion for one receiver. Only this proven pair
            // is one binding identity; other raw duplicates still veto binding.
            guard displayed.filter({ $0.identifier == identifier }).count == 1,
                  rows.allSatisfy({ confirmsUncachedEndpointIdentity($0, identifier: identifier) }),
                  rows.filter({ strictBoolean($0["isRemoteControlOnly"]) == false }).count == 1,
                  let companion = rows.first(where: { strictBoolean($0["isRemoteControlOnly"]) == true }),
                  companion["routingContextUUID"] is NSNull,
                  let streams = companion["streamUIDs"] as? [String], streams.isEmpty,
                  let statuses = companion["propertyStatus"] as? [String: Any],
                  successfulEndpointProperty(statuses["routingContextUUID"], state: "null"),
                  successfulEndpointProperty(statuses["streams"], state: "value"),
                  let streamReads = statuses["streamIdentifiers"] as? [Any], streamReads.isEmpty else { continue }
            // Empty projected streamUIDs alone cannot prove an empty native
            // array: failed element reads also omit IDs. The per-element read
            // inventory above must explicitly be empty after a successful read.
            binding.conflicted.remove(identifier)
            binding.confirmed.insert(identifier)
        }
        return binding
    }

    private static func confirmsUncachedEndpointIdentity(_ row: [String: Any], identifier: String) -> Bool {
        guard row["type"] as? String == "EndpointType_AirPlay",
              strictBoolean(row["isLocalDevice"]) == false,
              strictBoolean(row["wrapperIsCached"]) == false,
              let identity = row["avIdentity"] as? [String: Any],
              nonempty(identity["endpointIdentifier"]) == identifier,
              nonempty(identity["avDeviceIdentifier"]) == identifier,
              strictBoolean(identity["readbackStable"]) == true else { return false }
        // Raw IsCached is supplemental and may be unsupported. Its explicit
        // refusal or malformed non-null value cannot be overridden by wrapper evidence.
        guard let cached = row["isCached"], !(cached is NSNull) else { return true }
        return strictBoolean(cached) == false
    }

    private static func successfulEndpointProperty(_ value: Any?, state: String) -> Bool {
        guard let read = value as? [String: Any] else { return false }
        return read["state"] as? String == state && nonnegativeCount(read["status"]) == 0
    }

    static func systemSelection(_ raw: [String: Any]) -> SystemSelectionEvidence {
        let route = selectedRoute(raw)
        let unselected = raw["selection"] is NSNull && strictBoolean(raw["isUnselectedConfirmed"]) == true
        // Native reads can return a diagnostic dictionary after an unavailable
        // or inconsistent observation. Only verified selection or explicit
        // confirmed emptiness is healthy; diagnostic wording grants no evidence.
        let outcome: PrivateRouteReadOutcome = route != nil || unselected ? .succeeded : .failed
        return SystemSelectionEvidence(route: route,
                                diagnostics: "SystemAudio: \(raw["diagnostics"] ?? "unavailable")",
                                outcome: outcome, confirmsUnselectedAggregate: unselected)
    }

    static func retainedSystemRoute(_ raw: [String: Any]) -> RetainedSystemRouteEvidence {
        let diagnostics = "RetainedSystemAudio: \(raw["diagnostics"] ?? "unavailable")"
        guard strictBoolean(raw["sessionReadSucceeded"]) == true else {
            return RetainedSystemRouteEvidence(capability: nil, existingStreamAssociation: nil,
                                                memberComparison: nil, diagnostics: diagnostics, outcome: .failed)
        }
        let capability = retainedCapability(raw)
        let held = raw["retained"] as? [String: Any]
        let descriptor = held?["catalogRoute"] as? [String: Any]
        let strictDescriptor = strictBoolean(held?["canSelect"]) == true && strictBoolean(held?["isSelected"]) == false &&
            strictBoolean(descriptor?["readbackStable"]) == true ? capability?.validatedUnselectedRoute : nil
        return RetainedSystemRouteEvidence(capability: capability,
                                    existingStreamAssociation: existingStreamAssociation(raw),
                                    memberComparison: memberComparison(raw),
                                    diagnostics: diagnostics,
                                    outcome: .succeeded, verifiedUnselectedDescriptor: strictDescriptor,
                                    existingStreamRecovery: existingStreamRecovery(raw))
    }

    static func endpointRoutes(_ rows: [[String: Any]]) -> (routes: [PrivateAudioRoute], warning: String?) {
        let groups = Dictionary(grouping: eligibleEndpointRows(rows)) { $0["identifier"] as! String }
        var routes: [PrivateAudioRoute] = []
        var ambiguous = false
        for (identifier, matches) in groups.sorted(by: { $0.key < $1.key }) {
            guard matches.count == 1, let row = matches.first,
                  let name = row["name"] as? String else {
                ambiguous = true
                continue
            }
            routes.append(PrivateAudioRoute(identifier: identifier, name: name, uid: nil,
                                             isSelected: false, transportKind: .airplay,
                                             selectionCapability: .unavailable,
                                             icon: routeIcon(row, identifier: identifier)))
        }
        return (routes, ambiguous ? String(localized: "audio.airplay_identity_ambiguous", defaultValue: "Some AirPlay devices cannot be identified and are temporarily unavailable.") : nil)
    }

    private static func eligibleEndpointRows(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.filter {
            guard let features = $0["deviceFeatures"] as? NSNumber,
                  features.uint64Value & 1 != 0,
                  ($0["isRemoteControlOnly"] as? Bool) == false,
                  ($0["wrapperIsCached"] as? Bool) == false,
                  let identifier = $0["identifier"] as? String, !identifier.isEmpty,
                  let name = $0["name"] as? String, !name.isEmpty else { return false }
            return true
        }
    }

    private static func routeIcon(_ row: [String: Any], identifier: String) -> AudioDeviceIcon {
        guard let evidence = row["iconEvidence"] as? [String: Any],
              evidence["identifier"] as? String == identifier,
              evidence["readbackIdentifier"] as? String == identifier,
              strictBoolean(evidence["readbackStable"]) == true,
              let symbol = nonempty(evidence["symbolName"]) else { return .fallback }
        return .systemSymbol(symbol, modelIdentifier: nonempty(evidence["modelIdentifier"]))
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func nonnegativeCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let count = number.intValue
        guard count >= 0, number.compare(NSNumber(value: count)) == .orderedSame else { return nil }
        return count
    }

    private static func deviceEligibility(_ value: Any?) -> PrivateDeviceEligibility {
        guard let evidence = value as? [String: Any] else { return .unknown }
        let audio = strictBoolean(evidence["supportsAudio"])
        let cached = strictBoolean(evidence["isCached"])
        let disabled = strictBoolean(evidence["isDeviceDisabled"])
        let authorization = strictBoolean(evidence["requiresAuthorization"])
        if audio == false || cached == true || disabled == true || authorization == true { return .blocked }
        return audio == true && cached == false && disabled == false && authorization == false ? .eligible : .unknown
    }

    private static func endpointDeviceEligibility(_ row: [String: Any]) -> PrivateDeviceEligibility {
        // The raw cache getter is supplemental: some live endpoints cannot
        // provide it. Both wrapper observations must still explicitly allow
        // selection; unknown raw evidence is never rewritten as false. Preserve
        // an explicit raw restriction even when the wrapper appears permissive.
        if strictBoolean(row["isCached"]) == true { return .blocked }
        let flags = ["isRemoteControlOnly", "wrapperIsCached", "isDeviceDisabled", "requiresAuthorization"]
            .map { strictBoolean(row[$0]) }
        if flags.contains(true) { return .blocked }
        guard flags.allSatisfy({ $0 == false }), let features = row["deviceFeatures"] as? NSNumber,
              CFGetTypeID(features) == CFNumberGetTypeID() else { return .unknown }
        guard features.uint64Value & 1 != 0 else { return .blocked }
        return deviceEligibility(row["deviceEligibility"])
    }

    static func selectedRoute(_ snapshot: [String: Any]) -> PrivateAudioRoute? {
        guard let evidence = snapshot["selection"] as? [String: Any],
              let identifier = nonempty(evidence["identifier"]),
              let name = nonempty(evidence["name"]),
              let uid = nonempty(evidence["uid"]),
              nonempty(evidence["aggregateIdentifier"]) != nil,
              let context = nonempty(evidence["contextIdentifier"]),
              evidence["aggregateContextIdentifier"] as? String == context,
              evidence["associatedUID"] as? String == uid,
              evidence["halUID"] as? String == uid,
              evidence["audioStreamUIDs"] as? [String] == [uid],
              evidence["memberIdentifiers"] as? [String] == [identifier],
              strictBoolean(evidence["readbackStable"]) == true else { return nil }
        return PrivateAudioRoute(identifier: identifier, name: name, uid: uid, isSelected: true,
                                 transportKind: .airplay, selectionCapability: .unavailable)
    }

    static func retainedCapability(_ snapshot: [String: Any]) -> RetainedRouteCapability? {
        guard let retained = snapshot["retained"] as? [String: Any],
              let identifier = retained["identifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let canSelect = retained["canSelect"] as? Bool else { return nil }
        let uidEvidence = RouteStringEvidence(retained["associatedUID"])
        let uid = uidEvidence.string
        // The native bridge confirms present aggregate/member/stream/HAL
        // identity separately from permission to reuse the captured stream.
        // A changed capture generation can revoke switching without erasing a
        // fresh directory association. Legacy or malformed markers prove none.
        let associatedUID = strictBoolean(retained["associationReadbackStable"]) == true &&
            uid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? uid : nil
        let descriptor = retained["catalogRoute"] as? [String: Any]
        let descriptorUID = RouteStringEvidence(descriptor?["uid"])
        let descriptorUIDMatches = associatedUID.map { descriptorUID.string == $0 }
            ?? (uidEvidence == .null && descriptorUID == .null)
        let catalogRoute: PrivateAudioRoute?
        if canSelect, retained["state"] as? String == "retained", strictBoolean(retained["isSelected"]) == false,
           let descriptor,
           descriptor["identifier"] as? String == identifier,
           let name = descriptor["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           descriptor["transport"] as? String == "airplay", strictBoolean(descriptor["readbackStable"]) == true,
           descriptorUIDMatches {
            catalogRoute = PrivateAudioRoute(identifier: identifier, name: name, uid: associatedUID, isSelected: false,
                                             transportKind: .airplay, selectionCapability: .retainedAirPlay)
        } else {
            catalogRoute = nil
        }
        return RetainedRouteCapability(identifier: identifier, canSelect: canSelect,
                                       reason: retained["reason"] as? String, associatedUID: associatedUID,
                                       catalogRoute: catalogRoute)
    }

    static func existingStreamAssociation(_ snapshot: [String: Any]) -> ExistingSystemStreamAssociation? {
        guard let evidence = snapshot["existingStreamAssociation"] as? [String: Any],
              let identifier = evidence["identifier"] as? String, !identifier.isEmpty,
              let uid = evidence["uid"] as? String, !uid.isEmpty,
              let aggregate = evidence["aggregateIdentifier"] as? String, !aggregate.isEmpty,
              let context = evidence["contextIdentifier"] as? String, !context.isEmpty,
              evidence["readbackStable"] as? Bool == true,
              THExistingStreamUIDMatchesAggregate(uid, aggregate) else { return nil }
        return ExistingSystemStreamAssociation(identifier: identifier, uid: uid,
                                               aggregateIdentifier: aggregate, contextIdentifier: context)
    }

    static func existingStreamRecovery(_ snapshot: [String: Any]) -> ExistingSystemStreamRecovery? {
        // Only explicit absence of retained state admits this separate path.
        // A malformed or invalid capture must never be replaced by recovery.
        guard strictBoolean(snapshot["sessionReadSucceeded"]) == true,
              snapshot["retained"] is NSNull,
              let evidence = snapshot["existingStreamRecovery"] as? [String: Any],
              let identifier = nonempty(evidence["identifier"]),
              let name = nonempty(evidence["name"]),
              let uid = nonempty(evidence["uid"]),
              let aggregate = nonempty(evidence["aggregateIdentifier"]),
              let context = nonempty(evidence["contextIdentifier"]),
              [identifier, name, uid, aggregate, context].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              strictBoolean(evidence["readbackStable"]) == true,
              strictBoolean(evidence["canSelect"]) == true,
              THExistingStreamUIDMatchesAggregate(uid, aggregate) else { return nil }
        return ExistingSystemStreamRecovery(identifier: identifier, name: name, uid: uid,
                                             aggregateIdentifier: aggregate, contextIdentifier: context)
    }

    static func memberComparison(_ snapshot: [String: Any]) -> SystemRouteMemberComparison? {
        guard let diagnostics = snapshot["diagnostics"] as? [String: Any],
              let evidence = diagnostics["systemRouteMemberComparison"] as? [String: Any] else { return nil }
        return SystemRouteMemberComparison(systemContextMemberIDs: evidence["systemContextMemberIDs"] as? [String],
                                            rawAggregateMemberIDs: evidence["rawAggregateMemberIDs"] as? [String],
                                            readbackStable: evidence["readbackStable"] as? Bool == true,
                                            selectedForComparison: evidence["selectedForComparison"] as? Bool == true)
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}
