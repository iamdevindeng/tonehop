import Foundation

/// Fig objects and their callback run loop must stay on one OS thread. A serial
/// dispatch queue or an ordinary actor alone does not provide that guarantee.
final class AudioRouteExecutor: SerialExecutor, @unchecked Sendable {
    static let shared = AudioRouteExecutor()

    private let lock = NSCondition()
    private var jobs: [UnownedJob] = []
    private var runLoop: CFRunLoop?
    private var source: CFRunLoopSource?
    // Accessed only on the audio thread. Nested native run-loop pumping must
    // never start a second actor job while the first one is still executing.
    private var executing = false

    private init() {
        let thread = Thread { [self] in
            var context = CFRunLoopSourceContext()
            context.info = Unmanaged.passUnretained(self).toOpaque()
            context.perform = { info in
                guard let info else { return }
                Unmanaged<AudioRouteExecutor>.fromOpaque(info).takeUnretainedValue().drain()
            }
            let loop = CFRunLoopGetCurrent()!
            let signal = CFRunLoopSourceCreate(nil, 0, &context)!
            CFRunLoopAddSource(loop, signal, .defaultMode)
            lock.lock()
            runLoop = loop
            source = signal
            lock.broadcast()
            lock.unlock()
            CFRunLoopRun()
        }
        thread.name = "ToneHop.AudioRoutes"
        thread.qualityOfService = .userInitiated
        thread.start()
        lock.lock()
        while source == nil { lock.wait() }
        lock.unlock()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        lock.lock()
        jobs.append(UnownedJob(job))
        let signal = source!
        let loop = runLoop!
        lock.unlock()
        CFRunLoopSourceSignal(signal)
        CFRunLoopWakeUp(loop)
    }

    var queuedJobCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.count
    }

    private func drain() {
        guard !executing else { return }
        executing = true
        defer { executing = false }
        while true {
            lock.lock()
            let job = jobs.isEmpty ? nil : jobs.removeFirst()
            lock.unlock()
            guard let job else { return }
            autoreleasepool { job.runSynchronously(on: asUnownedSerialExecutor()) }
        }
    }
}
