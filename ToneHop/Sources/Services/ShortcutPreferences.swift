import Foundation
import Darwin

struct ShortcutBinding: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let target: AudioTargetIdentity
    let shortcut: DeviceShortcut
    let lastKnownName: String
    let revision: UUID

    init(id: UUID = UUID(), target: AudioTargetIdentity, shortcut: DeviceShortcut,
         lastKnownName: String, revision: UUID = UUID()) {
        self.id = id
        self.target = target
        self.shortcut = shortcut
        self.lastKnownName = lastKnownName
        self.revision = revision
    }
}

protocol ShortcutPreferencesProviding: Sendable {
    /// nil means the document does not exist. An existing empty document is a
    /// deliberate configuration and must never receive first-launch defaults.
    func load() async throws -> [ShortcutBinding]?
    /// Must leave the previous document intact when throwing.
    func save(_ bindings: [ShortcutBinding]) async throws
}

/// Synchronous file access stays on the repository's private serial queue. The
/// seam also permits a held disk operation without blocking the test/UI actor.
protocol ShortcutPreferencesFileAccess: Sendable {
    func read(_ url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
}

private struct SystemShortcutPreferencesFileAccess: ShortcutPreferencesFileAccess {
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// One open file description owns the writer lease from the first read through
/// the last accepted write. The stable lock file is never unlinked: replacing
/// its inode would let another instance acquire a different, ineffective lock.
private final class ShortcutPreferencesWriterLease: @unchecked Sendable {
    private struct Session {
        let descriptor: Int32
        let fileURL: URL
    }
    private let fileURL: URL
    private let lock = NSLock()
    private var session: Session?

    init(fileURL: URL) { self.fileURL = fileURL }

    func acquire() throws -> URL {
        try lock.withLock {
            if let session { return session.fileURL }
            // Resolving aliases may touch disk. Only the repository's I/O
            // queue calls acquire; construction on MainActor stays inert.
            let requestedURL = fileURL.standardizedFileURL
            let requestedParent = requestedURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: requestedParent,
                                                    withIntermediateDirectories: true)
            // Resolving the full path can leave aliases intact when the leaf
            // is absent. Resolve the now-existing parent first, then the leaf
            // separately so an existing document symlink is handled as well.
            let canonicalURL = requestedParent.resolvingSymlinksInPath()
                .appendingPathComponent(requestedURL.lastPathComponent)
                .resolvingSymlinksInPath()
            let lockURL = canonicalURL.appendingPathExtension("lock")
            let candidate = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                                 S_IRUSR | S_IWUSR)
            guard candidate >= 0 else { throw systemError(operation: String(localized: "shortcut.open_configuration_lock", defaultValue: "Open shortcut configuration lock"), status: errno) }
            guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
                let status = errno
                _ = Darwin.close(candidate)
                if status == EWOULDBLOCK || status == EAGAIN {
                    throw ShortcutError.unavailable(String(localized: "shortcut.configuration_in_use", defaultValue: "Another instance is using the shortcut configuration. Quit that instance, then reload."))
                }
                throw systemError(operation: String(localized: "shortcut.lock_configuration", defaultValue: "Lock shortcut configuration"), status: status)
            }
            session = Session(descriptor: candidate, fileURL: canonicalURL)
            return canonicalURL
        }
    }

    private func systemError(operation: String, status: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: String(localized: "shortcut.configuration_operation_failed", defaultValue: "\(operation) failed (\(Int(status))). Check the configuration folder, then reload.")])
    }

    deinit {
        // Queue operations retain this lease through their actual I/O return.
        // Closing the last descriptor releases flock; process death does too.
        if let session { _ = Darwin.close(session.descriptor) }
    }
}

final class ShortcutPreferences: ShortcutPreferencesProviding {
    private struct Document: Codable {
        let version: Int
        let bindings: [ShortcutBinding]
    }
    private struct Header: Decodable { let version: Int }
    /// The requested location, for diagnostics. Lock and data I/O resolve it
    /// together off-main and keep that destination fixed for the owned session.
    let fileURL: URL
    private let fileAccess: any ShortcutPreferencesFileAccess
    private let writerLease: ShortcutPreferencesWriterLease
    private let queue = DispatchQueue(label: "com.dengziyi.ToneHop.shortcut-preferences", qos: .utility)

    init(fileURL: URL? = nil, fileAccess: any ShortcutPreferencesFileAccess = SystemShortcutPreferencesFileAccess()) {
        let requestedURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask)[0]
            .appendingPathComponent("ToneHop", isDirectory: true)
            .appendingPathComponent("shortcuts.json")
        self.fileURL = requestedURL
        self.fileAccess = fileAccess
        self.writerLease = ShortcutPreferencesWriterLease(fileURL: self.fileURL)
    }

    func load() async throws -> [ShortcutBinding]? {
        try await perform { [fileAccess] fileURL in try Self.read(fileURL, using: fileAccess) }
    }

    private static func read(_ fileURL: URL, using fileAccess: any ShortcutPreferencesFileAccess) throws -> [ShortcutBinding]? {
        let data: Data
        do { data = try fileAccess.read(fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == 1 else { throw ShortcutError.unsupportedVersion(header.version) }
            let document = try decoder.decode(Document.self, from: data)
            try Self.validate(document.bindings)
            return document.bindings
        } catch let error as ShortcutError { throw error }
        catch { throw ShortcutError.invalidConfiguration }
    }

    func save(_ bindings: [ShortcutBinding]) async throws {
        try await perform { [fileAccess] fileURL in
            try Self.validate(bindings)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(version: 1, bindings: bindings))
            try fileAccess.writeAtomically(data, to: fileURL)
        }
    }

    private func perform<Value: Sendable>(_ operation: @escaping @Sendable (URL) throws -> Value) async throws -> Value {
        // Cancellation cannot prove that an atomic replacement did not happen.
        // Always resume after the real operation; Store shutdown drains it.
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [writerLease] in
                do {
                    let value = try withExtendedLifetime(writerLease) {
                        let destination = try writerLease.acquire()
                        return try operation(destination)
                    }
                    continuation.resume(returning: value)
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func validate(_ bindings: [ShortcutBinding]) throws {
        var ids = Set<UUID>(), targets = Set<AudioTargetIdentity>(), shortcuts = Set<DeviceShortcut>()
        for binding in bindings {
            let identity: String
            switch binding.target {
            case let .hal(uid): identity = uid
            case let .receiver(identifier): identity = identifier
            }
            guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(binding.id).inserted,
                  targets.insert(binding.target).inserted,
                  shortcuts.insert(binding.shortcut).inserted else { throw ShortcutError.invalidConfiguration }
        }
    }
}
