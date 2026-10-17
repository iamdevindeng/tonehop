import AppKit

/// Native alerts run from an AppKit event, outside a running Swift actor job.
/// The awaiting quit task suspends so audio callbacks and UI updates can run.
@MainActor
enum QuitAlerts {
    static func confirmation(for plan: AudioExitPlan) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "ui.quit.title", defaultValue: "Quit ToneHop?")
        let receiver = plan.ownedStream?.name ?? String(localized: "ui.quit.receiver_fallback", defaultValue: "AirPlay device")
        alert.informativeText = String(localized: "ui.quit.message", defaultValue: "This will disconnect audio from “\(receiver)” and switch output to your Mac’s built-in speakers.")
        alert.addButton(withTitle: String(localized: "ui.quit.confirm", defaultValue: "Switch and Quit"))
        alert.addButton(withTitle: String(localized: "ui.cancel", defaultValue: "Cancel")).keyEquivalent = "\u{1b}"
        return alert
    }

    static func confirm(_ plan: AudioExitPlan) async -> Bool {
        await present(confirmation(for: plan)) == .alertFirstButtonReturn
    }

    private static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    NSApp.activate()
                    continuation.resume(returning: alert.runModal())
                }
            }
        }
    }
}
