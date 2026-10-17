import Foundation

/// Pure composition of AV discovery, endpoint discovery, system selection,
/// retained capability, existing-stream identity and distinct recovery permission. AV discovery
/// keeps precedence unless current endpoint-wrapper and retained evidence prove
/// the same unselected receiver and explicitly rule out device restrictions.
enum PrivateRouteCatalog {
    static func merge(av: AVRouteDiscoveryEvidence, endpoints: EndpointDiscoveryEvidence,
                      selection: SystemSelectionEvidence, retained: RetainedSystemRouteEvidence) -> PrivateRouteSnapshot {
        // AV and endpoint discovery can describe devices, but only the strict
        // SystemAudio readback may mark one as selected in the merged catalog.
        var routes = av.routes.map(discoveredRoute)
        let existingIDs = Set(routes.map(\.identifier))
        routes += endpoints.routes.filter { !existingIDs.contains($0.identifier) }.map(discoveredRoute)

        if selection.outcome == .succeeded, let selected = selection.route {
            // A fully verified selected aggregate outranks discovery. It does
            // not itself grant the retained capability needed for another write.
            routes.removeAll { $0.identifier == selected.identifier }
            routes.append(selected)
        }
        routes = supplementRetainedCapability(routes, av: av, endpoints: endpoints, selection: selection, retained: retained)
        // Removing AV claims from formal selected state must not broaden the
        // existing fallback that introduces an undiscovered retained receiver.
        let avReportsSelection = av.selectionEvidence.values.contains { $0.isSelected == true }
            || av.routes.contains(where: \.isSelected)
        routes = RetainedRouteCapability.applying(retained.capability, to: routes,
                                                  allowUndiscoveredRoute: !avReportsSelection)
        routes = ExistingSystemStreamAssociation.applying(retained.existingStreamAssociation, to: routes)
        routes = supplementExistingStreamRecovery(routes, av: av, endpoints: endpoints,
                                                   selection: selection, retained: retained)
        routes = applyingDeviceIcons(to: routes, av: av, endpoints: endpoints)
        let hasUnavailableReceiver = routes.contains { $0.transportKind == .airplay && !$0.canSelect && !$0.isSelected }
        let issue = hasUnavailableReceiver ?
            (retained.capability?.reason ?? RetainedRouteCapability.preparationHint) : ""
        let health = PrivateRouteSourceHealth(avDiscovery: av.outcome, endpointDiscovery: endpoints.outcome,
                                              systemSelection: selection.outcome, retainedRoute: retained.outcome)
        let catalogWarning = endpoints.warning ?? (max(av.elapsed, endpoints.elapsed) >= 8 && !issue.isEmpty ? issue : nil)
        let warnings = [health.warning, catalogWarning].compactMap { $0 }
        var bindingIDs = av.bindingIdentity.confirmed.union(endpoints.bindingIdentity.confirmed)
        if selection.outcome == .succeeded, let selected = selection.route { bindingIDs.insert(selected.identifier) }
        if let held = retained.verifiedUnselectedDescriptor { bindingIDs.insert(held.identifier) }
        bindingIDs.subtract(av.bindingIdentity.conflicted.union(endpoints.bindingIdentity.conflicted))
        let uniqueFinalIDs = Set(Dictionary(grouping: routes, by: \.identifier).filter { !$0.key.isEmpty && $0.value.count == 1 }.keys)
        bindingIDs.formIntersection(uniqueFinalIDs)
        return PrivateRouteSnapshot(
            routes: routes,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"),
            diagnostics: av.diagnostics + "; " + endpoints.diagnostics + "; " + selection.diagnostics + "; " + retained.diagnostics + "; AV issue: " + (av.issue ?? "none")
                + "; ShortcutIdentity: avConfirmed=\(av.bindingIdentity.confirmed.sorted()), avConflicted=\(av.bindingIdentity.conflicted.sorted()), endpointConfirmed=\(endpoints.bindingIdentity.confirmed.sorted()), endpointConflicted=\(endpoints.bindingIdentity.conflicted.sorted()), finalConfirmed=\(bindingIDs.sorted())",
            systemRouteMemberComparison: retained.memberComparison,
            sourceHealth: health,
            selectedVolumeAssociation: selection.outcome == .succeeded ? selection.route.flatMap { route in
                route.uid.map { SystemRouteVolumeAssociation(identifier: route.identifier, uid: $0) }
            } : nil,
            confirmedShortcutIdentifiers: bindingIDs,
            discovery: discoveryInventory(av: av, endpoints: endpoints, selection: selection)
        )
    }

    private static func discoveryInventory(av: AVRouteDiscoveryEvidence, endpoints: EndpointDiscoveryEvidence,
                                          selection: SystemSelectionEvidence) -> AudioDiscoverySourceInventory {
        var identifiers = av.discovery.observedIdentifiers.union(endpoints.discovery.observedIdentifiers)
        if selection.outcome == .succeeded, let selected = selection.route { identifiers.insert(selected.identifier) }
        let conflicts = av.discovery.conflictedIdentifiers.union(endpoints.discovery.conflictedIdentifiers)
        // Both sessions start asynchronously. This existing discovery settling
        // interval only withholds early absence; it is not a permanence test or
        // proof that our sources exactly match Control Center on every system.
        let settled = av.elapsed.isFinite && endpoints.elapsed.isFinite && min(av.elapsed, endpoints.elapsed) >= 8
        return AudioDiscoverySourceInventory(observedIdentifiers: identifiers, conflictedIdentifiers: conflicts,
            isComplete: settled && av.outcome == .succeeded && endpoints.outcome == .succeeded
                && selection.outcome == .succeeded && av.discovery.isComplete && endpoints.discovery.isComplete)
    }

    private static func discoveredRoute(_ route: PrivateAudioRoute) -> PrivateAudioRoute {
        PrivateAudioRoute(identifier: route.identifier, name: route.name, uid: route.uid,
                          isSelected: false, transportKind: route.transportKind,
                          selectionCapability: route.selectionCapability, unavailableReason: route.unavailableReason,
                          icon: route.icon)
    }

    /// A strict selected route replaces discovery's capability/selection fields,
    /// then receives optional presentation metadata by the same complete receiver
    /// identity. Conflicting symbols or raw identity conflicts always fall back.
    private static func applyingDeviceIcons(to routes: [PrivateAudioRoute], av: AVRouteDiscoveryEvidence,
                                           endpoints: EndpointDiscoveryEvidence) -> [PrivateAudioRoute] {
        let samples = av.routes + endpoints.routes
        let icons = Dictionary(grouping: samples, by: \.identifier)
        let conflicts = av.bindingIdentity.conflicted.union(endpoints.bindingIdentity.conflicted)
            .union(av.discovery.conflictedIdentifiers).union(endpoints.discovery.conflictedIdentifiers)
        return routes.map { route in
            var result = route
            let candidates = icons[route.identifier, default: []].map(\.icon).filter { $0.source == .systemSymbol }
            guard !conflicts.contains(route.identifier),
                  Set(candidates.map(\.symbolName)).count == 1, let icon = candidates.first else {
                result.icon = .fallback
                return result
            }
            result.icon = icon
            return result
        }
    }

    private static func supplementRetainedCapability(_ routes: [PrivateAudioRoute], av: AVRouteDiscoveryEvidence,
        endpoints: EndpointDiscoveryEvidence, selection: SystemSelectionEvidence,
        retained: RetainedSystemRouteEvidence) -> [PrivateAudioRoute] {
        guard av.outcome == .succeeded, endpoints.outcome == .succeeded,
              selection.outcome == .succeeded, retained.outcome == .succeeded,
              selection.confirmsUnselectedAggregate, selection.route == nil, !routes.contains(where: \.isSelected),
              !av.routes.contains(where: \.isSelected),
              !av.selectionEvidence.values.contains(where: { $0.isSelected == true }),
              let held = retained.verifiedUnselectedDescriptor,
              av.routes.filter({ $0.identifier == held.identifier }).count == 1,
              endpoints.routes.filter({ $0.identifier == held.identifier }).count == 1,
              av.selectionEvidence[held.identifier]?.lacksOnlyWritableContext == true,
              endpoints.avIdentityEvidence[held.identifier]?.confirms(held.identifier) == true else { return routes }

        // The new path must not resolve conflicting UID evidence by precedence.
        // An empty verified aggregate also cannot adopt an explicit AV stream.
        if let association = retained.existingStreamAssociation,
           association.identifier != held.identifier || association.uid != held.uid { return routes }
        if let uid = held.uid, routes.contains(where: { $0.identifier != held.identifier && $0.uid == uid }) { return routes }
        return routes.map { route in
            guard route.identifier == held.identifier, route.transportKind == .other("unknown"),
                  route.selectionCapability == .unavailable, !route.isSelected,
                  route.uid == nil || route.uid == held.uid else { return route }
            return PrivateAudioRoute(identifier: route.identifier, name: route.name, uid: held.uid,
                                     isSelected: false, transportKind: held.transportKind,
                                     selectionCapability: held.selectionCapability, icon: route.icon)
        }
    }

    private static func supplementExistingStreamRecovery(_ routes: [PrivateAudioRoute], av: AVRouteDiscoveryEvidence,
        endpoints: EndpointDiscoveryEvidence, selection: SystemSelectionEvidence,
        retained: RetainedSystemRouteEvidence) -> [PrivateAudioRoute] {
        guard av.outcome == .succeeded, endpoints.outcome == .succeeded,
              selection.outcome == .succeeded, retained.outcome == .succeeded,
              selection.confirmsUnselectedAggregate, selection.route == nil,
              !routes.contains(where: \.isSelected), !av.routes.contains(where: \.isSelected),
              !av.selectionEvidence.values.contains(where: { $0.isSelected == true }),
              retained.capability == nil, let recovery = retained.existingStreamRecovery,
              routes.filter({ $0.identifier == recovery.identifier }).count == 1,
              endpoints.routes.filter({ $0.identifier == recovery.identifier }).count == 1,
              endpoints.bindingIdentity.confirmed.contains(recovery.identifier) else { return routes }
        let conflicts = av.bindingIdentity.conflicted.union(endpoints.bindingIdentity.conflicted)
            .union(av.discovery.conflictedIdentifiers).union(endpoints.discovery.conflictedIdentifiers)
        guard !conflicts.contains(recovery.identifier),
              !routes.contains(where: { $0.identifier != recovery.identifier && $0.uid == recovery.uid }) else { return routes }
        if let association = retained.existingStreamAssociation,
           association.identifier != recovery.identifier || association.uid != recovery.uid ||
           association.aggregateIdentifier != recovery.aggregateIdentifier || association.contextIdentifier != recovery.contextIdentifier {
            return routes
        }
        let avMatches = av.routes.filter { $0.identifier == recovery.identifier }
        if !avMatches.isEmpty {
            // Preserve AV precedence unless the same fully verified wrapper
            // evidence used for retained supplementation explains its denial.
            guard avMatches.count == 1,
                  av.selectionEvidence[recovery.identifier]?.lacksOnlyWritableContext == true,
                  endpoints.avIdentityEvidence[recovery.identifier]?.confirms(recovery.identifier) == true else { return routes }
        }
        return routes.map { route in
            guard route.identifier == recovery.identifier, !route.isSelected,
                  route.selectionCapability == .unavailable,
                  route.transportKind == .airplay || route.transportKind == .other("unknown"),
                  route.uid == nil || route.uid == recovery.uid else { return route }
            return PrivateAudioRoute(identifier: route.identifier, name: route.name, uid: recovery.uid,
                                     isSelected: false, transportKind: .airplay,
                                     selectionCapability: .existingSystemStream, icon: route.icon)
        }
    }
}
