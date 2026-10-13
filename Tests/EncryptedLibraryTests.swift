import AppKit
import CryptoKit

private struct Failure: Error { let message: String }
private func check(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private final class TestDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
}

@main struct EncryptedLibraryTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EncryptedLibraryTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("store/library.enc")
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let disk = EncryptedLibraryDisk(url: url, keyProvider: { _ in secret })
        let defaults = TestDefaults()
        let recent = RecentFileEntry(id: UUID(), url: URL(fileURLWithPath: "/private-example/Confidential.pdf"), bookmark: Data("test-permission".utf8))
        defaults.values["recentPDFs"] = try JSONEncoder().encode([recent])
        defaults.values["readOnlyFolders"] = ["/private-example": Data("folder-permission".utf8)]
        var contents = try LibraryContents.legacy(defaults: defaults)
        let migrated = try await disk.load(migrating: contents)
        try check(migrated.recentFiles.first?.id == recent.id && migrated.folders.count == 1, "Migration must preserve files and folder approvals")
        let bytes = try Data(contentsOf: url)
        try check(bytes.range(of: Data("Confidential".utf8)) == nil && bytes.range(of: Data("private-example".utf8)) == nil && bytes.range(of: Data("folder-permission".utf8)) == nil,
                  "Disk contents must not expose names, paths or bookmark contents")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "Encrypted file must have owner-only permissions")
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        try check(directoryPermissions?.intValue == 0o700, "Storage directory must be private")
        let reopened = EncryptedLibraryDisk(url: url, keyProvider: { create in
            try check(!create, "Existing store must never silently create a replacement key")
            return secret
        })
        let restored = try await reopened.load(migrating: LibraryContents())
        try check(restored.recentFiles.first?.url == recent.url, "Encrypted history must survive a new store instance")
        try await disk.save(contents)
        try check(try Data(contentsOf: url) != bytes, "Every save must use a fresh encryption nonce")
        let valid = try Data(contentsOf: url)
        var tampered = valid; tampered[tampered.count - 1] ^= 1; try tampered.write(to: url)
        do { _ = try await reopened.load(migrating: contents); throw Failure(message: "Tampering accepted") }
        catch LibraryStorageError.invalidData {}
        try check(try Data(contentsOf: url) == tampered, "Rejected store must not be overwritten")
        try valid.write(to: url)
        let wrongKey = EncryptedLibraryDisk(url: url, keyProvider: { _ in Data(repeating: 7, count: 32) })
        do { _ = try await wrongKey.load(migrating: contents); throw Failure(message: "Wrong key accepted") }
        catch LibraryStorageError.invalidData {}
        let denied = EncryptedLibraryDisk(url: url, keyProvider: { _ in throw LibraryStorageError.keychain(errSecAuthFailed) })
        do { _ = try await denied.load(migrating: contents); throw Failure(message: "Denied keychain accepted") }
        catch LibraryStorageError.keychain {}
        try check(try Data(contentsOf: url) == valid, "Key failure must preserve encrypted data")
        print("PASS: migration, restart, AES-GCM authentication, private permissions, fresh nonce and failure preservation")

        contents = LibraryContents()
        let start = Date()
        for index in 0..<10_000 {
            contents.rememberFolder(URL(fileURLWithPath: "/folder-\(index)"), bookmark: Data(repeating: UInt8(index % 256), count: 800))
        }
        // Reusing the oldest folder makes it the most recently used.
        contents.rememberFolder(URL(fileURLWithPath: "/folder-0"), bookmark: Data([42]))
        contents.rememberFolder(URL(fileURLWithPath: "/folder-10000"), bookmark: Data([43]))
        try check(contents.folders.count == 10_000 && contents.folders["/folder-0"] != nil && contents.folders["/folder-1"] == nil,
                  "Overflow must discard only the least recently used approval")
        try await disk.save(contents)
        let large = try await reopened.load(migrating: LibraryContents())
        try check(large.folders.count == 10_000 && large.folders["/folder-0"]?.bookmark == Data([42]), "10,000 approvals must survive encryption and reload")
        print("PASS: 10,000 folders, least-recently-used eviction and encrypted round trip (\(String(format: "%.2f", Date().timeIntervalSince(start))) s)")
        try await disk.save(LibraryContents())
        let cleared = try await reopened.load(migrating: contents)
        try check(cleared.folders.isEmpty && cleared.recentFiles.isEmpty, "Clearing must persist and never remigrate stale legacy data")
        let unavailableURL = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: unavailableURL)
        let unwritable = EncryptedLibraryDisk(url: unavailableURL.appendingPathComponent("library.enc"), keyProvider: { _ in secret })
        do { _ = try await unwritable.load(migrating: contents); throw Failure(message: "Failed write accepted") }
        catch is CocoaError {}
        try check(defaults.data(forKey: "recentPDFs") != nil, "Failed migration cannot discard legacy input")
        print("PASS: durable clearing and failed-write preservation")
        try checkShortcuts()
        print("All encrypted-library and shortcut checks passed.")
    }

    @MainActor static func checkShortcuts() throws {
        func event(_ key: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                            isARepeat: false, keyCode: 0)!
        }
        let mappings: [(String, NSEvent.ModifierFlags, ReaderShortcut)] = [
            ("w", .command, .closeWindow), ("+", [.command,.shift], .zoomIn), ("=", .command, .zoomIn),
            ("-", .command, .zoomOut), ("0", .command, .actualSize), ("9", .command, .fit),
            ("r", .command, .rotateCurrent), ("r", [.command,.option], .rotateAll)
        ]
        for (key, flags, result) in mappings {
            try check(ReaderShortcut.command(for: event(key, flags)) == result, "Shortcut must match \(key)")
        }
        for key in ["f", "s", "c", "a", "p", "r"] {
            try check(ReaderShortcut.command(for: event(key, [.control,.command])) == nil, "Unassigned combinations must not trigger reader actions")
        }
        try check(ReaderShortcut.command(for: event("r", [])) == nil, "Plain text must not rotate")
        print("PASS: reader shortcut mapping and modifier isolation; Find and Save remain unassigned")
    }
}
