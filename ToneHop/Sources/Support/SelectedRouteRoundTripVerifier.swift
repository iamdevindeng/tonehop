#if DEBUG
import Foundation
import OSLog

/// Explicit developer-only integration check. Ordinary launches and the
/// read-only diagnostics modes never enter this path. Uses the same store
/// action as a device-row click; it does not call private APIs itself.
@MainActor
enum SelectedRouteRoundTripVerifier {
    struct Configuration: Decodable {
        let receiverID: String
        let localUID: String
        let outputPath: String
        /// True verifies a disabled cold-start row without selecting audio by default.
        /// Omission preserves the original selected-receiver round trip.
        let startFromLocal: Bool?
        /// Explicitly exercise cold-start recovery through store.select, then
        /// leave and return using the ordinary captured route path.
        let coldStartRecovery: Bool?
        /// Only with startFromLocal: wait for an external system selection,
        /// capture it in this process, then run the ordinary round trip.
        let waitForSystemSelectionAfterColdStart: Bool?
        /// Explicit test preparation only. This is not Bedroom exit acceptance.
        let finishOnLocal: Bool?
    }

    static func run(store: AudioStore, configurationURL: URL) async {
        let logger = Logger(subsystem: "com.dengziyi.ToneHop", category: "SelectedRouteVerification")
        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              !configuration.receiverID.isEmpty, !configuration.localUID.isEmpty,
              configuration.outputPath.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: configuration.outputPath),
              FileManager.default.createFile(atPath: configuration.outputPath, contents: nil),
              let file = try? FileHandle(forWritingTo: URL(fileURLWithPath: configuration.outputPath)) else {
            logger.error("Verification configuration or fresh output file unavailable; no selection requested")
            return
        }
        defer { try? file.close() }
        let receiverID = "route:\(configuration.receiverID)"
        let localID = "hal:\(configuration.localUID)"
        let coldStartRecovery = configuration.coldStartRecovery ?? false
        let startFromLocal = coldStartRecovery || (configuration.startFromLocal ?? false)
        let waitForSystemSelectionAfterColdStart = startFromLocal && !coldStartRecovery &&
            (configuration.waitForSystemSelectionAfterColdStart ?? false)
        var requests = 0
        var capturedStreamUID: String?
        var receiverSelectionMemberComparison: SystemRouteMemberComparison?

        func record(_ phase: String, _ result: String) {
            logger.info("Verification phase=\(phase, privacy: .public) result=\(result, privacy: .public)")
            let devices = (try? JSONEncoder().encode(store.devices))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            let hardware = store.lastHardwareSnapshot.flatMap { try? JSONEncoder().encode($0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            let row: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "pid": ProcessInfo.processInfo.processIdentifier,
                "buildInfo": BuildInfo.current.diagnosticFields,
                "phase": phase, "result": result, "selectionRequests": requests,
                "currentDeviceID": store.currentDeviceID as Any? ?? NSNull(),
                "isSwitching": store.isSwitching, "feedback": store.feedback,
                "devices": devices, "hardware": hardware,
                "privateDiagnostics": store.lastRouteSnapshot?.diagnostics ?? "not sampled",
                "systemRouteMemberComparison": store.lastRouteSnapshot?.systemRouteMemberComparison?.diagnosticFields as Any? ?? NSNull(),
                "receiverSelectionMemberComparison": receiverSelectionMemberComparison?.diagnosticFields as Any? ?? NSNull(),
                "systemHandoffVerification": "not-performed",
                "invocation": "explicit-debug-selected-route-round-trip",
                "startFromLocal": startFromLocal,
                "coldStartRecovery": coldStartRecovery,
                "waitForSystemSelectionAfterColdStart": waitForSystemSelectionAfterColdStart,
            ]
            if var encoded = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) {
                encoded.append(0x0A)
                try? file.write(contentsOf: encoded)
            }
        }
        func receiverRoute() -> PrivateAudioRoute? {
            let matches = store.lastRouteSnapshot?.routes.filter {
                $0.identifier == configuration.receiverID
            } ?? []
            return matches.count == 1 ? matches.first : nil
        }
        func receiverDevice() -> AudioDevice? {
            let matches = store.devices.filter { $0.id == receiverID }
            guard matches.count == 1, let receiver = matches.first,
                  receiver.backend == .privateRoute(identifier: configuration.receiverID) else { return nil }
            return receiver
        }
        func localDevice() -> AudioDevice? {
            store.devices.first {
                $0.id == localID && $0.isAvailable && $0.backend == .coreAudio(uid: configuration.localUID)
                    && $0.transport != .airplay
            }
        }
        func selectionIsConfirmed(_ identifier: String) -> Bool {
            guard !store.isSwitching, store.currentDeviceID == identifier,
                  let hardware = store.lastHardwareSnapshot else { return false }
            if identifier == localID {
                return hardware.currentDeviceID == localID && localDevice() != nil
            }
            guard identifier == receiverID, let route = receiverRoute(), route.isSelected, route.canSelect,
                  let uid = route.uid, !uid.isEmpty, receiverDevice()?.isAvailable == true else { return false }
            // Require the private receiver selection and the exact active HAL
            // stream to agree; a success label alone is not system readback.
            return hardware.devices.contains {
                $0.id == hardware.currentDeviceID && $0.backend == .coreAudio(uid: uid) && $0.transport == .airplay
            }
        }
        func waitForSelection(_ identifier: String) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if !store.isSwitching {
                    return selectionIsConfirmed(identifier) && store.feedbackKind == .success
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return false }
            }
            return false
        }
        func localCatalogIsConsistent() -> Bool {
            guard selectionIsConfirmed(localID), let receiver = receiverDevice(),
                  let uid = capturedStreamUID, !uid.isEmpty else { return false }
            guard receiver.isAvailable else { return false }
            let streamSurvives = store.lastHardwareSnapshot?.devices.contains {
                $0.backend == .coreAudio(uid: uid)
            } == true
            guard streamSurvives else { return true }
            // Successful output readback alone missed this regression: the
            // same receiver was also exposed as a raw selectable HAL AirPlay.
            return !store.devices.contains { $0.backend == .coreAudio(uid: uid) } &&
                receiverRoute().map { $0.uid == uid && !$0.isSelected } == true
        }
        func coldStartupIsConsistent() -> Bool {
            guard selectionIsConfirmed(localID), let receiver = receiverDevice(),
                  !receiver.isAvailable, receiver.unavailableReason?.isEmpty == false,
                  let route = receiverRoute(), !route.canSelect, !route.isSelected,
                  let hardware = store.lastHardwareSnapshot else { return false }
            // A surviving HAL stream must be folded into a disabled receiver,
            // never exposed as an alternate clickable path around the boundary.
            let streams = hardware.devices.filter { $0.transport == .airplay }
            guard !streams.isEmpty else { return true }
            guard let uid = route.uid, !uid.isEmpty else { return false }
            return streams.contains { $0.backend == .coreAudio(uid: uid) } &&
                !store.devices.contains { $0.backend == .coreAudio(uid: uid) } &&
                !store.devices.contains { $0.transport == .airplay && $0.isAvailable }
        }
        func coldRecoveryIsConsistent() -> Bool {
            guard selectionIsConfirmed(localID), let receiver = receiverDevice(), receiver.isAvailable,
                  let route = receiverRoute(), !route.isSelected,
                  route.selectionCapability == .existingSystemStream,
                  let uid = route.uid, !uid.isEmpty,
                  store.lastHardwareSnapshot?.devices.contains(where: {
                      $0.backend == .coreAudio(uid: uid) && $0.transport == .airplay
                  }) == true else { return false }
            return !store.devices.contains { $0.backend == .coreAudio(uid: uid) }
        }
        func selectReceiver() async -> Bool {
            // Recheck immediately before the normal store action. No fallback
            // system selection or retry manufactures a successful test.
            guard !Task.isCancelled, localCatalogIsConsistent(),
                  let receiver = receiverDevice(), receiver.isAvailable else {
                record("finish", "receiver-unavailable-before-selection")
                return false
            }
            requests += 1
            store.select(receiver)
            record("receiver-request", "submitted")
            guard await waitForSelection(receiverID) else {
                record("finish", "receiver-switch-not-confirmed")
                return false
            }
            capturedStreamUID = receiverRoute()?.uid
            record("receiver-confirmed", "success")
            return true
        }

        record("startup", coldStartRecovery ? "waiting-for-recoverable-local-startup-receiver" :
            startFromLocal ? "waiting-for-disabled-local-startup-receiver" : "waiting-for-already-selected-receiver")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var ready = false
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if coldStartRecovery {
                ready = coldRecoveryIsConsistent()
                if ready { capturedStreamUID = receiverRoute()?.uid }
            } else if startFromLocal {
                ready = coldStartupIsConsistent()
            } else {
                ready = selectionIsConfirmed(receiverID)
                if ready { capturedStreamUID = receiverRoute()?.uid }
            }
            if ready, localDevice() != nil { break }
            ready = false
            do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
        }
        guard ready, !Task.isCancelled else {
            record("finish", startFromLocal ? "local-receiver-association-precondition-failed" : "selected-receiver-or-local-precondition-failed")
            return
        }
        record(startFromLocal ? "local-start-confirmed" : "captured", "ready-without-selection-request")
        if coldStartRecovery {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, coldRecoveryIsConsistent() else {
                record("finish", "cold-start-recovery-not-stable")
                return
            }
            record("cold-start-recovery", "normal-store-selection-ready")
            guard await selectReceiver() else { return }
            record("cold-start-recovery-confirmed", "strict-receiver-and-hal-readback-passed")
        } else if startFromLocal {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, coldStartupIsConsistent() else {
                record("finish", "cold-start-boundary-not-stable")
                return
            }
            guard waitForSystemSelectionAfterColdStart else {
                record("finish", "local-start-disabled-without-selection-request")
                return
            }
            record("external-selection-wait", "cold-start-disabled-without-selection-request")
            let systemSelectionDeadline = ContinuousClock.now.advanced(by: .seconds(180))
            var externalSelectionCaptured = false
            while !Task.isCancelled, ContinuousClock.now < systemSelectionDeadline {
                if selectionIsConfirmed(receiverID) {
                    capturedStreamUID = receiverRoute()?.uid
                    externalSelectionCaptured = true
                    break
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
            guard externalSelectionCaptured, !Task.isCancelled else {
                record("finish", Task.isCancelled ? "cancelled-waiting-for-system-selection" : "system-selection-not-captured")
                return
            }
            record("external-selection-captured", "ready-without-selection-request")
        }

        guard !Task.isCancelled, selectionIsConfirmed(receiverID), let local = localDevice() else {
            record("finish", "selection-changed-before-leave")
            return
        }
        requests += 1
        store.select(local)
        record("local-request", "submitted")
        guard await waitForSelection(localID) else {
            record("finish", "local-switch-not-confirmed")
            return
        }
        record("local-confirmed", "success")
        guard localCatalogIsConsistent() else {
            record("finish", "duplicate-or-unassociated-receiver-after-leave")
            return
        }
        // Include ordinary discovery refreshes while local remains selected.
        do { try await Task.sleep(for: .seconds(4)) } catch {
            record("finish", "cancelled-during-local-observation")
            return
        }
        store.refresh()
        do { try await Task.sleep(for: .milliseconds(300)) } catch {
            record("finish", "cancelled-after-local-refresh")
            return
        }
        let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isRefreshing, !Task.isCancelled, ContinuousClock.now < refreshDeadline {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        guard !Task.isCancelled, !store.isRefreshing else {
            record("finish", "local-refresh-not-completed")
            return
        }
        guard localCatalogIsConsistent() else {
            record("finish", "receiver-association-lost-after-refresh")
            return
        }
        record("local-catalog-confirmed", "stable-receiver-row-without-duplicate-transport")
        if await selectReceiver() {
            // Keep the successful audio readback separate from the system's
            // member directory. Even a match cannot prove later Quit/reconnect.
            receiverSelectionMemberComparison = store.lastRouteSnapshot?.systemRouteMemberComparison
            let memberResult = receiverSelectionMemberComparison?.confirmsSelectedReceiver(configuration.receiverID) == true ?
                "matched-selected-receiver" : receiverSelectionMemberComparison?.comparison == .mismatch ? "mismatch" : "unknown"
            record("audio-round-trip-confirmed", "audio-selection-readback-passed")
            record("system-route-member-check", memberResult)
            if configuration.finishOnLocal == true {
                guard !Task.isCancelled, let local = localDevice() else { return }
                requests += 1
                store.select(local)
                record("test-local-cleanup-request", "explicit-test-preparation-not-exit-acceptance")
                guard await waitForSelection(localID) else {
                    record("finish", "test-local-cleanup-not-confirmed")
                    return
                }
                record("test-local-cleanup-confirmed", "success")
            }
            record("finish", "audio-readback-passed-system-members-\(memberResult)-exit-handoff-not-verified")
        }
    }
}
#endif
