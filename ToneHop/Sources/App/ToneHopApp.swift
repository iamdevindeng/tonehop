import AppKit

/// A menu-bar-only application: no main window or Dock activation at launch.
@main
@MainActor
enum ToneHopApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: AudioStore
    private let interactions: AudioInteractionCoordinator?
    private let quitMenu: NSMenu
    private let confirmTermination: @MainActor (AudioExitPlan) async -> Bool
    private let recordTerminationFailure: @MainActor (any Error) async -> Void
    private let replyToTermination: @MainActor (NSApplication, Bool) -> Void
    private let isHostedTestInstance: Bool
    private var statusBarController: StatusBarController?
    private enum TerminationState { case running, preparing, ready }
    private var terminationState = TerminationState.running
    private var diagnosticObservation: Task<Void, Never>?
    private var selectedRouteVerification: Task<Void, Never>?
    private var terminationSignal: DispatchSourceSignal?

    override convenience init() {
        let hosted = ProcessInfo.processInfo.environment["TONEHOP_TESTING"] == "1"
        let quitMenu = StatusBarController.makeQuitMenu()
        #if DEBUG
        if !hosted, ProcessInfo.processInfo.arguments.contains("--preview-r08-for-testing") {
            let fixture = R08PreviewFixture.make(quitMenu: quitMenu)
            self.init(store: fixture.store, interactions: fixture.interactions, quitMenu: quitMenu,
                      confirm: QuitAlerts.confirm, recordFailure: AppDelegate.recordQuitFailure,
                      reply: { $0.reply(toApplicationShouldTerminate: $1) }, isHostedTestInstance: false)
            return
        }
        #endif
        let hardware = CoreAudioService()
        let store = AudioStore(hardware: hardware)
        let interactions: AudioInteractionCoordinator?
        if hosted { interactions = nil }
        else {
            let volume = AudioVolumeStore(provider: hardware, resolveTarget: { [weak store] id in
                guard let store else { throw CancellationError() }
                return try await store.resolveVolumeTarget(deviceID: id)
            })
            let preferences: ShortcutPreferences
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--show-popover-for-testing"),
               let index = arguments.firstIndex(of: "--shortcut-preferences-for-testing"),
               arguments.count > index + 1 {
                preferences = ShortcutPreferences(fileURL: URL(fileURLWithPath: arguments[index + 1]))
            } else { preferences = ShortcutPreferences() }
            #else
            preferences = ShortcutPreferences()
            #endif
            let shortcuts = ShortcutStore(selectTarget: { [weak store] target, request in
                store?.select(target: target, request: request)
            }, preferences: preferences, menuConflict: { shortcut in
                StatusBarController.shortcutConflict(shortcut, quitMenu: quitMenu, mainMenu: NSApp.mainMenu)
            }, initialBinding: {
                try? await FirstLaunchShortcut.builtInSpeaker(using: hardware)
            })
            interactions = AudioInteractionCoordinator(audio: store, shortcuts: shortcuts, volume: volume)
        }
        self.init(store: store, interactions: interactions, quitMenu: quitMenu, confirm: QuitAlerts.confirm,
                  recordFailure: AppDelegate.recordQuitFailure,
                  reply: { $0.reply(toApplicationShouldTerminate: $1) },
                  isHostedTestInstance: hosted)
    }

    /// The injected instance exercises the normal delegate entry without
    /// allowing a hosted XCTest to terminate its own process or present UI.
    convenience init(store: AudioStore,
                     confirm: @escaping @MainActor (AudioExitPlan) async -> Bool = QuitAlerts.confirm,
                     recordFailure: @escaping @MainActor (any Error) async -> Void = AppDelegate.recordQuitFailure,
                     reply: @escaping @MainActor (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }) {
        self.init(store: store, interactions: nil, quitMenu: StatusBarController.makeQuitMenu(),
                  confirm: confirm, recordFailure: recordFailure,
                  reply: reply, isHostedTestInstance: false)
    }

    private init(store: AudioStore,
                 interactions: AudioInteractionCoordinator?,
                 quitMenu: NSMenu,
                 confirm: @escaping @MainActor (AudioExitPlan) async -> Bool,
                 recordFailure: @escaping @MainActor (any Error) async -> Void,
                 reply: @escaping @MainActor (NSApplication, Bool) -> Void,
                 isHostedTestInstance: Bool) {
        self.store = store
        self.interactions = interactions
        self.quitMenu = quitMenu
        self.confirmTermination = confirm
        self.recordTerminationFailure = recordFailure
        self.replyToTermination = reply
        self.isHostedTestInstance = isHostedTestInstance
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if isHostedTestInstance { return }
        // The project run script sends TERM before rebuilding. Route it through
        // the same coordinated shutdown as the menu's Quit command.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { Self.scheduleTermination() }
        termination.resume()
        terminationSignal = termination

        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--diagnostics"), arguments.count > index + 1 {
            let destination = URL(fileURLWithPath: arguments[index + 1])
            Task {
                await DiagnosticsRunner.run(store: store, outputURL: destination)
                Self.scheduleTermination()
            }
            return
        }

        statusBarController = StatusBarController(store: store, interactions: interactions, quitMenu: quitMenu)
        interactions?.start()
        store.start()
        if let index = arguments.firstIndex(of: "--live-diagnostics"), arguments.count > index + 1 {
            let destination = URL(fileURLWithPath: arguments[index + 1])
            diagnosticObservation = Task {
                await DiagnosticsRunner.observe(store: store, outputURL: destination)
            }
        }
        #if DEBUG
        if arguments.contains("--show-popover-for-testing") {
            // Wait until launch setup has returned to the main run loop.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.terminationState == .running else { return }
                self.statusBarController?.showPopoverForTesting()
            }
        }
        if let index = arguments.firstIndex(of: "--verify-selected-round-trip"), arguments.count > index + 1 {
            let configuration = URL(fileURLWithPath: arguments[index + 1])
            selectedRouteVerification = Task {
                await SelectedRouteRoundTripVerifier.run(store: store, configurationURL: configuration)
            }
        }
        #endif
    }

    nonisolated private static func scheduleTermination() {
        // Deliver termination as an AppKit event, outside a running Swift job.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isHostedTestInstance { return .terminateNow }
        if terminationState == .ready { return .terminateNow }
        guard terminationState == .running else { return .terminateLater }
        terminationState = .preparing
        store.beginQuitPreparation()
        #if DEBUG
        statusBarController?.cancelTestingPresentation()
        #endif
        Task {
            do {
                let plan = try await store.prepareToQuit()
                if plan.requiresConfirmation, !(await confirmTermination(plan)) {
                    store.cancelQuit()
                    terminationState = .running
                    replyToTermination(sender, false)
                    return
                }
                selectedRouteVerification?.cancel()
                try await store.confirmQuit()
            } catch {
                await recordTerminationFailure(error)
                terminationState = .running
                replyToTermination(sender, false)
                return
            }
            diagnosticObservation?.cancel()
            terminationState = .ready
            replyToTermination(sender, true)
        }
        // Keep the original AppKit request pending, including logout/restart.
        // Cancel would abandon that request; a later self-terminate cannot resume it.
        return .terminateLater
    }

    static func recordQuitFailure(_ error: any Error) async {
        NSLog("Quit did not complete: %@", error.localizedDescription)
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stop()
    }
}
