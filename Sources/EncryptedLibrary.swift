import Foundation
import CryptoKit
import Security

struct FolderApproval: Codable {
    var bookmark: Data
    var lastUsed: UInt64
}

struct LibraryContents: Codable {
    var version = 1
    var recentFiles: [RecentFileEntry] = []
    var folders: [String: FolderApproval] = [:]
    var accessCounter: UInt64 = 0
    static let folderLimit = 10_000

    mutating func rememberFolder(_ url: URL, bookmark: Data) {
        let path = url.standardizedFileURL.path
        accessCounter += 1
        if folders[path] == nil, folders.count >= Self.folderLimit,
           let oldest = folders.min(by: {
               $0.value.lastUsed == $1.value.lastUsed ? $0.key < $1.key : $0.value.lastUsed < $1.value.lastUsed
           })?.key { folders.removeValue(forKey: oldest) }
        folders[path] = FolderApproval(bookmark: bookmark, lastUsed: accessCounter)
    }

    static func legacy(defaults: UserDefaults) throws -> LibraryContents {
        var result = LibraryContents()
        if let data = defaults.data(forKey: "recentPDFs") {
            result.recentFiles = Array(try JSONDecoder().decode([RecentFileEntry].self, from: data).prefix(10))
        }
        // Older versions did not retain usage order; stable order is used only for migration.
        let folders = defaults.dictionary(forKey: "readOnlyFolders") as? [String: Data] ?? [:]
        for path in folders.keys.sorted() {
            result.rememberFolder(URL(fileURLWithPath: path), bookmark: folders[path]!)
        }
        return result
    }
}

enum LibraryStorageError: LocalizedError {
    case keychain(OSStatus), missingKey, invalidData, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .keychain:
            return "macOS Keychain did not allow access to the encryption key. Unlock your login keychain or approve Jack’s PDF if macOS asks, then restart the app."
        case .missingKey:
            return "The encryption key for saved history is missing from macOS Keychain. Existing saved data has been left unchanged."
        case .invalidData:
            return "Saved history could not be verified or decrypted. Existing saved data has been left unchanged."
        case .unsupportedVersion:
            return "Saved history was created by an unsupported version of Jack’s PDF. Update the app to read it."
        }
    }
}

enum LibraryKeychain {
    static let service = "com.nikhilsharma.JacksPDFViewer.encrypted-library"
    static func load(createIfMissing: Bool) throws -> Data {
        // The local login keychain works with ad-hoc signed macOS apps. Its ACL trusts
        // only the creating application. Never broaden that ACL to avoid update prompts.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "library-key-v1",
            kSecUseDataProtectionKeychain as String: false
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw LibraryStorageError.keychain(status) }
        guard createIfMissing else { throw LibraryStorageError.missingKey }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var access: SecAccess?
        let accessStatus = SecAccessCreate("Jack’s PDF encrypted history" as CFString, nil, &access)
        guard accessStatus == errSecSuccess, let access else { throw LibraryStorageError.keychain(accessStatus) }
        var attributes = query
        attributes[kSecValueData as String] = key
        attributes[kSecAttrLabel as String] = "Jack’s PDF encrypted history"
        attributes[kSecAttrAccess as String] = access
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem { return try load(createIfMissing: false) }
        guard addStatus == errSecSuccess else { throw LibraryStorageError.keychain(addStatus) }
        return key
    }
}

/// A serial background actor owns encryption and disk IO. No decoded paths or bookmarks
/// are written to preferences, logs or a plaintext sidecar. Only an active folder is leased.
actor EncryptedLibraryDisk {
    let url: URL
    private let keyProvider: (Bool) throws -> Data
    private var key: SymmetricKey?
    private static let magic = Data("JACKSPDF-LIBRARY-1\n".utf8)

    init(url: URL, keyProvider: @escaping (Bool) throws -> Data = { try LibraryKeychain.load(createIfMissing: $0) }) {
        self.url = url
        self.keyProvider = keyProvider
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jack's PDF", isDirectory: true).appendingPathComponent("library.enc")
    }

    func load(migrating legacy: LibraryContents) throws -> LibraryContents {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let data = try keyProvider(!exists)
        guard data.count == 32 else { throw LibraryStorageError.invalidData }
        key = SymmetricKey(data: data)
        if exists { return try decode(Data(contentsOf: url)) }
        try save(legacy)
        // Do not discard legacy preferences until a verified read succeeds.
        return try decode(Data(contentsOf: url))
    }

    func save(_ contents: LibraryContents) throws {
        guard let key else { throw LibraryStorageError.missingKey }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let plaintext = try JSONEncoder().encode(contents)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.magic)
        guard let combined = sealed.combined else { throw LibraryStorageError.invalidData }
        let encrypted = Self.magic + combined
        // Validate the sealed payload before atomically replacing the prior file.
        _ = try decode(encrypted)
        try encrypted.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var location = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }

    private func decode(_ data: Data) throws -> LibraryContents {
        guard let key, data.starts(with: Self.magic) else { throw LibraryStorageError.invalidData }
        let result: LibraryContents
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count))
            let plaintext = try AES.GCM.open(box, using: key, authenticating: Self.magic)
            result = try JSONDecoder().decode(LibraryContents.self, from: plaintext)
        } catch { throw LibraryStorageError.invalidData }
        guard result.version == 1 else { throw LibraryStorageError.unsupportedVersion }
        guard result.folders.count <= LibraryContents.folderLimit, result.recentFiles.count <= 10,
              result.folders.values.allSatisfy({ $0.lastUsed <= result.accessCounter }) else {
            throw LibraryStorageError.invalidData
        }
        return result
    }
}
