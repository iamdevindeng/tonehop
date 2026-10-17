import AppKit
import Foundation

/// A read-only path through the same services and signed bundle as the product.
/// It never calls select, opens Control Center, or starts playback.
@MainActor
enum DiagnosticsRunner {
    /// Optional observation of the interactive App. This observer issues no
    /// selections; user clicks still travel through the ordinary view/store.
    static func observe(store: AudioStore, outputURL: URL) async {
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let file = try? FileHandle(forWritingTo: outputURL) else { return }
        defer { try? file.close() }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        while !Task.isCancelled {
            let encoded = try? JSONEncoder().encode(store.devices)
            let rows = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            let hardware = store.lastHardwareSnapshot.flatMap { try? JSONEncoder().encode($0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            let record: [String: Any] = [
                "at": timestamp.string(from: Date()),
                "pid": ProcessInfo.processInfo.processIdentifier,
                "buildInfo": BuildInfo.current.diagnosticFields,
                "devices": rows,
                "hardware": hardware,
                "currentDeviceID": store.currentDeviceID as Any? ?? NSNull(),
                "isSwitching": store.isSwitching,
                "feedback": store.feedback,
                "warning": store.catalogWarning as Any? ?? NSNull(),
                "privateDiagnostics": store.lastRouteSnapshot?.diagnostics ?? "not sampled",
                "observerOnly": true,
            ]
            if var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                data.append(0x0A)
                try? file.write(contentsOf: data)
            }
            // Explicit diagnostics only; normal launches install no observer.
            // Keep raw HAL alongside the presentation to inspect short gaps.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    static func run(store: AudioStore, outputURL: URL) async {
        store.start()
        var samples: [[String: Any]] = []
        // Include steady-state samples beyond initial discovery; an initial
        // receiver sighting alone does not prove a persistent live directory.
        for delay in [1, 2, 5, 6, 8, 12, 12] {
            try? await Task.sleep(for: .seconds(delay))
            let encoded = try? JSONEncoder().encode(store.devices)
            let rows = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            samples.append([
                "at": ISO8601DateFormatter().string(from: Date()),
                "devices": rows,
                "currentDeviceID": store.currentDeviceID as Any? ?? NSNull(),
                "systemSoundDeviceID": store.lastHardwareSnapshot?.systemSoundDeviceID as Any? ?? NSNull(),
                "warning": store.catalogWarning as Any? ?? NSNull(),
                "privateDiagnostics": store.lastRouteSnapshot?.diagnostics ?? "not sampled",
            ])
        }
        let report: [String: Any] = [
            "readOnly": true,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "buildInfo": BuildInfo.current.diagnosticFields,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "samples": samples,
            "limitations": ["No output selection or playback was performed.",
                            "This does not prove Control Center equivalence or audible playback."],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL, options: .atomic)
        } catch { NSLog("Diagnostics write failed: %@", error.localizedDescription) }
        // AppDelegate owns coordinated termination. Do not stop the services
        // here and bypass the shutdown failure path before AppKit can decide.
    }
}
