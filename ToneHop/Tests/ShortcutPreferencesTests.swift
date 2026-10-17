import XCTest
@testable import ToneHop

@MainActor
final class ShortcutPreferencesTests: XCTestCase {
    private func binding(target: AudioTargetIdentity = .receiver(identifier: "full:receiver:id"),
                         code: UInt16 = 40) throws -> ShortcutBinding {
        ShortcutBinding(target: target, shortcut: try .init(keyCode: code, modifiers: [.command, .option]),
                        lastKnownName: "Bedroom")
    }

    func testRoundTripPreservesFullIdentityAndRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = ShortcutPreferences(fileURL: directory.appendingPathComponent("shortcuts.json"))
        let initially = try await preferences.load()
        XCTAssertNil(initially)
        let saved = try [binding(), binding(target: .hal(uid: "full:opaque:UID"), code: 38)]
        try await preferences.save(saved)
        let restored = try await preferences.load()
        XCTAssertEqual(restored, saved)
        try await preferences.save([])
        let empty = try await preferences.load()
        XCTAssertEqual(empty, [])
    }

    func testExclusiveWriterLeaseRejectsSecondInstanceAcrossLoadAndSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shortcuts.json")
        let owner = ShortcutPreferences(fileURL: file)
        let contender = ShortcutPreferences(fileURL: file)
        let initial = try await owner.load()
        XCTAssertNil(initial)
        await assertFailure { try await contender.load() }
        let first = try binding()
        let second = try binding(target: .hal(uid: "another-device"), code: 38)
        try await owner.save([first])
        await assertFailure { try await contender.save([second]) }
        let saved = try await owner.load()
        XCTAssertEqual(saved, [first], "An atomic replacement must not overwrite another instance's document.")
    }

    func testExclusiveWriterLeaseReleasedWithOwnerAndRecoveryReadsLatestDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shortcuts.json")
        var owner: ShortcutPreferences? = ShortcutPreferences(fileURL: file)
        let contender = ShortcutPreferences(fileURL: file)
        let first = try binding()
        try await owner?.save([first])
        await assertFailure { try await contender.load() }
        owner = nil
        let recovered = try await contender.load()
        XCTAssertEqual(recovered, [first])
        let second = try binding(target: .hal(uid: "another-device"), code: 38)
        try await contender.save(try XCTUnwrap(recovered) + [second])
        let saved = try await contender.load()
        XCTAssertEqual(saved, [first, second])
    }

    func testExclusiveWriterLeaseProtectsRejectedDocumentUntilOwnerReleases() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("shortcuts.json")
        let original = Data("invalid-json".utf8)
        try original.write(to: file)
        let owner = ShortcutPreferences(fileURL: file)
        let contender = ShortcutPreferences(fileURL: file)
        await assertFailure { try await owner.load() }
        let replacement = try binding()
        await assertFailure { try await contender.save([replacement]) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testExclusiveWriterLeaseKeepsDifferentConfigurationsIndependent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ShortcutPreferences(fileURL: directory.appendingPathComponent("first.json"))
        let second = ShortcutPreferences(fileURL: directory.appendingPathComponent("second.json"))
        let a = try binding()
        let b = try binding(target: .hal(uid: "another-device"), code: 38)
        try await first.save([a])
        try await second.save([b])
        let firstReadback = try await first.load()
        let secondReadback = try await second.load()
        XCTAssertEqual(firstReadback, [a])
        XCTAssertEqual(secondReadback, [b])
    }

    func testExclusiveWriterLeaseTreatsSymlinkedParentAsSameMissingDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let owner = ShortcutPreferences(fileURL: real.appendingPathComponent("shortcuts.json"))
        let contender = ShortcutPreferences(fileURL: alias.appendingPathComponent("shortcuts.json"))
        let initial = try await owner.load()
        XCTAssertNil(initial)
        await assertFailure { try await contender.load() }
        let first = try binding()
        try await owner.save([first])
        await assertFailure { try await contender.save([]) }
        let saved = try await owner.load()
        XCTAssertEqual(saved, [first])
    }

    func testExclusiveWriterLeaseKeepsResolvedDestinationWhenAliasChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original", isDirectory: true)
        let replacement = directory.appendingPathComponent("replacement", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let relativeFile = "not-created-yet/nested/shortcuts.json"
        let owner = ShortcutPreferences(fileURL: alias.appendingPathComponent(relativeFile))
        _ = try await owner.load()
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)
        let saved = try binding()
        try await owner.save([saved])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent(relativeFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.appendingPathComponent(relativeFile).path))
        let contender = ShortcutPreferences(fileURL: original.appendingPathComponent(relativeFile))
        await assertFailure { try await contender.load() }
        let readback = try await owner.load()
        XCTAssertEqual(readback, [saved], "A session must not write a retargeted path while holding its original lock.")
    }

    func testExclusiveWriterLeaseCanRetryAfterLockCreationFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shortcuts.json")
        let lockFile = file.appendingPathExtension("lock")
        try FileManager.default.createDirectory(at: lockFile, withIntermediateDirectories: true)
        let preferences = ShortcutPreferences(fileURL: file)
        await assertFailure { try await preferences.load() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: lockFile)
        let initial = try await preferences.load()
        XCTAssertNil(initial)
        let first = try binding()
        try await preferences.save([first])
        let saved = try await preferences.load()
        XCTAssertEqual(saved, [first])
    }

    func testExclusiveWriterLeaseKeepsStableLockInodeAfterOwnerRelease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shortcuts.json")
        let lockFile = file.appendingPathExtension("lock")
        var owner: ShortcutPreferences? = ShortcutPreferences(fileURL: file)
        _ = try await owner?.load()
        let original = try FileManager.default.attributesOfItem(atPath: lockFile.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotNil(original)
        owner = nil
        let contender = ShortcutPreferences(fileURL: file)
        _ = try await contender.load()
        let reopened = try FileManager.default.attributesOfItem(atPath: lockFile.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(reopened, original, "Deleting the lock file would split exclusion across different inodes.")
    }

    func testExclusiveWriterLeaseOutlivesAcceptedWriteAndCallerCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shortcuts.json")
        let access = HeldShortcutFileAccess()
        var owner: ShortcutPreferences? = ShortcutPreferences(fileURL: file, fileAccess: access)
        let contender = ShortcutPreferences(fileURL: file)
        let saved = try binding()
        let writing = Task { [preferences = try XCTUnwrap(owner)] in try await preferences.save([saved]) }
        defer { access.release.signal() }
        let entered = await XCTWaiter.fulfillment(of: [access.writeEntered], timeout: 2)
        XCTAssertEqual(entered, .completed)
        owner = nil
        writing.cancel()
        await assertFailure { try await contender.load() }
        access.release.signal()
        try await writing.value
        // The injected write is memory-only. Once it actually returns, a new
        // owner can acquire the lease and read the still-absent disk document.
        let initial = try await contender.load()
        XCTAssertNil(initial)
    }

    func testCorruptAndFutureVersionDocumentsArePreserved() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let preferences = ShortcutPreferences(fileURL: file)
        for text in ["invalid-json", "{\"version\":99,\"bindings\":[]}"] {
            let data = Data(text.utf8)
            try data.write(to: file)
            await assertFailure { try await preferences.load() }
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testDuplicateTargetsKeysAndIDsAreRejectedWithoutReplacingExistingFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let preferences = ShortcutPreferences(fileURL: file)
        let first = try binding()
        try await preferences.save([first])
        let data = try Data(contentsOf: file)
        let sameTarget = try binding(code: 38)
        let sameKey = try binding(target: .hal(uid: "other"))
        let sameID = ShortcutBinding(id: first.id, target: .hal(uid: "other"),
                                     shortcut: try .init(keyCode: 38, modifiers: .command), lastKnownName: "Other")
        for second in [sameTarget, sameKey, sameID] {
            await assertFailure { try await preferences.save([first, second]) }
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testDecodingCannotBypassCombinationValidation() throws {
        let invalid = Data("{\"keyCode\":40,\"modifiers\":{\"rawValue\":4}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceShortcut.self, from: invalid))
        let valid = try DeviceShortcut(keyCode: 40, modifiers: .command)
        XCTAssertEqual(try JSONDecoder().decode(DeviceShortcut.self, from: JSONEncoder().encode(valid)), valid)
    }

    func testStoreRecoveryPreservesRejectedBytesAndOnlyLoadsAnExplicitlyRepairedDocument() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = try binding()
        for text in ["invalid-json", "{\"version\":99,\"bindings\":[]}"] {
            let original = Data(text.utf8)
            try original.write(to: file)
            let preferences = ShortcutPreferences(fileURL: file)
            let registrar = ShortcutTestRegistrar()
            let store = ShortcutStore(selectTarget: { _, _ in XCTFail("Recovery cannot select audio") },
                                      preferences: preferences, registrar: registrar)
            store.start()
            await store.drain()
            for _ in 0..<2 {
                XCTAssertEqual(store.recoveryTitle, expectedLocalized("Reload", "重新读取"))
                XCTAssertFalse(store.canEdit)
                store.retryRecovery()
                await store.drain()
                XCTAssertEqual(try Data(contentsOf: file), original)
                XCTAssertTrue(registrar.registered.isEmpty)
            }
            // Simulate a user restoring a known document outside the running
            // Store. The recovery action itself never writes or resets it.
            var repaired = Data("{\"version\":1,\"bindings\":[".utf8)
            repaired.append(try JSONEncoder().encode(saved))
            repaired.append(Data("]}".utf8))
            try repaired.write(to: file, options: .atomic)
            store.retryRecovery()
            await store.drain()
            XCTAssertEqual(store.bindings, [saved])
            XCTAssertEqual(registrar.registered.count, 1)
            XCTAssertTrue(store.canEdit)
            XCTAssertEqual(try Data(contentsOf: file), repaired)
            store.stop()
        }
    }

    func testFileQueueIsSerialOffMainAndCancellationWaitsForActualWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = HeldShortcutFileAccess()
        let preferences = ShortcutPreferences(fileURL: directory.appendingPathComponent("shortcuts.json"), fileAccess: access)
        let saved = try binding()
        let writing = Task { try await preferences.save([saved]) }
        defer { access.release.signal() }
        let entered = await XCTWaiter.fulfillment(of: [access.writeEntered], timeout: 2)
        XCTAssertEqual(entered, .completed)
        writing.cancel()
        let reading = Task { try await preferences.load() }
        let notOverlapping = await XCTWaiter.fulfillment(of: [access.prematureRead], timeout: 0.05)
        XCTAssertEqual(notOverlapping, .completed)
        XCTAssertEqual(access.snapshot().events, ["write-entered"])
        XCTAssertFalse(access.snapshot().usedMainThread)
        access.release.signal()
        try await writing.value
        let restored = try await reading.value
        XCTAssertEqual(restored, [saved])
        XCTAssertEqual(access.snapshot().events, ["write-entered", "write-returned", "read"])
        XCTAssertFalse(access.snapshot().usedMainThread)
    }

    private func assertFailure<Value: Sendable>(_ operation: @MainActor () async throws -> Value,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected failure", file: file, line: line) }
        catch {}
    }
}

private final class HeldShortcutFileAccess: ShortcutPreferencesFileAccess, @unchecked Sendable {
    let writeEntered = XCTestExpectation(description: "background file write entered")
    let prematureRead: XCTestExpectation = {
        let value = XCTestExpectation(description: "read cannot overtake held write")
        value.isInverted = true
        return value
    }()
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()
    private var events: [String] = []
    private var usedMainThread = false
    private var writeReturned = false

    func read(_ url: URL) throws -> Data {
        lock.withLock {
            usedMainThread = usedMainThread || Thread.isMainThread
            events.append("read")
            if !writeReturned { prematureRead.fulfill() }
            return data
        }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.withLock {
            usedMainThread = usedMainThread || Thread.isMainThread
            events.append("write-entered")
        }
        writeEntered.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else {
            throw ShortcutError.unavailable("Test file operation was not released")
        }
        lock.withLock {
            self.data = data
            writeReturned = true
            events.append("write-returned")
        }
    }

    func snapshot() -> (events: [String], usedMainThread: Bool) {
        lock.withLock { (events, usedMainThread) }
    }
}
