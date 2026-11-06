import AppKit
import PDFKit
import Darwin

enum PDFSupportError: Error, LocalizedError {
    case passwordRequired, incorrectPassword, unreadablePDF, emptyDocument
    case sourceChanged, originalOverwriteForbidden, encryptedExportUnsupported, invalidRotation
    case unsafeDestination(String), writeFailed(String), fileAccess(String)

    var errorDescription: String? {
        switch self {
        case .passwordRequired: return "This PDF requires a password."
        case .incorrectPassword: return "The password was not accepted. Please try again."
        case .unreadablePDF: return "This file could not be opened as a PDF. It may be damaged or unsupported."
        case .emptyDocument: return "This PDF does not contain any pages."
        case .sourceChanged: return "The original PDF changed, moved, or was removed. Reopen it before saving a rotated copy."
        case .originalOverwriteForbidden: return "Choose a different filename. The original PDF cannot be replaced, including through a link or an alias of its path."
        case .encryptedExportUnsupported: return "This encrypted PDF can be viewed, but saving rotated copies is unavailable because its protection cannot be safely preserved."
        case .invalidRotation: return "The requested page rotation is invalid. Reopen the PDF and try again."
        case .unsafeDestination(let reason): return "The copy cannot be saved here. \(reason)"
        case .writeFailed(let reason): return "The PDF copy could not be saved. \(reason)"
        case .fileAccess(let reason): return "The file could not be accessed. \(reason)"
        }
    }
}

/// Identity and change markers describe the source that was actually read, not just its name.
struct FileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    fileprivate init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
        byteCount = information.st_size
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        changeSeconds = Int64(information.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(information.st_ctimespec.tv_nsec)
    }

    static func capture(url: URL) throws -> FileIdentity {
        var information = stat()
        guard url.isFileURL, url.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return fstatat(AT_FDCWD, path, &information, 0) == 0
        }), (information.st_mode & S_IFMT) == S_IFREG else {
            throw PDFSupportError.fileAccess("Select a readable, regular PDF file.")
        }
        return FileIdentity(information)
    }

    func isSameFile(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

/// A private file-backed snapshot keeps lazy PDFKit reads consistent and limits memory use.
/// The viewing document belongs to its UI owner; exports create a separate PDFDocument.
final class LoadedPDF: @unchecked Sendable {
    let document: PDFDocument
    let sourceURL: URL
    let snapshotURL: URL
    let identity: FileIdentity
    let byteCount: Int64
    let password: String?
    let snapshotUsesCopyOnWrite: Bool
    fileprivate let canonicalSourceURL: URL
    private let lease: SnapshotLease

    fileprivate init(document: PDFDocument, sourceURL: URL, identity: FileIdentity,
                     password: String?, lease: SnapshotLease, snapshotUsesCopyOnWrite: Bool) {
        self.document = document
        self.sourceURL = sourceURL.standardizedFileURL
        canonicalSourceURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        snapshotURL = lease.directory.appendingPathComponent("document.pdf")
        self.identity = identity
        byteCount = identity.byteCount
        self.password = password
        self.snapshotUsesCopyOnWrite = snapshotUsesCopyOnWrite
        self.lease = lease
    }
}

private final class SnapshotLease {
    let directory: URL
    private let lockDescriptor: Int32
    private static let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("JacksPDFViewer-Snapshots", isDirectory: true)
    private static let cleanupOnce: Void = {
        let manager = FileManager.default
        try? manager.createDirectory(at: baseDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        guard let folders = try? manager.contentsOfDirectory(at: baseDirectory,
                         includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let descriptor = open(folder.appendingPathComponent("lease").path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            if descriptor >= 0 {
                // An active process holds this lock for the entire snapshot lifetime.
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    try? manager.removeItem(at: folder)
                }
                close(descriptor)
            } else if errno == ENOENT {
                // A process may have exited between creating its folder and its lease file.
                try? manager.removeItem(at: folder)
            }
        }
    }()

    init() throws {
        _ = Self.cleanupOnce
        directory = Self.baseDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        lockDescriptor = open(directory.appendingPathComponent("lease").path,
                              O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockDescriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw PDFSupportError.fileAccess("A private working copy could not be created.")
        }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(lockDescriptor)
            try? FileManager.default.removeItem(at: directory)
            throw PDFSupportError.fileAccess("The private working copy could not be secured.")
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        close(lockDescriptor)
    }
}

enum PDFLoader {
    static func load(url: URL, password: String? = nil) async throws -> LoadedPDF {
        try await backgroundWork {
            guard url.isFileURL else { throw PDFSupportError.unreadablePDF }
            let lease = try SnapshotLease()
            let snapshot = lease.directory.appendingPathComponent("document.pdf")
            let (identity, usedClone) = try copyStableFile(from: url, to: snapshot)
            guard let document = PDFDocument(url: snapshot) else { throw PDFSupportError.unreadablePDF }
            if document.isLocked {
                guard let password else { throw PDFSupportError.passwordRequired }
                guard document.unlock(withPassword: password) else { throw PDFSupportError.incorrectPassword }
            }
            guard document.pageCount > 0 else { throw PDFSupportError.emptyDocument }
            return LoadedPDF(document: document, sourceURL: url, identity: identity,
                             password: password, lease: lease, snapshotUsesCopyOnWrite: usedClone)
        }
    }
}

enum RotationExport {
    static func save(source: LoadedPDF, rotations: [Int: Int], destinationURL: URL) async throws {
        try await backgroundWork {
            try performSave(source: source, rotations: rotations, destinationURL: destinationURL)
        }
    }

    private static func performSave(source: LoadedPDF, rotations: [Int: Int], destinationURL: URL) throws {
        guard destinationURL.isFileURL else {
            throw PDFSupportError.unsafeDestination("Choose a local file or a mounted folder.")
        }
        try verifySource(source)
        let destination = destinationURL.standardizedFileURL
        try verifyDestinationIsNotSource(destination, source: source)
        let filename = destination.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.utf8.contains(0), destination.pathExtension.lowercased() == "pdf" else {
            throw PDFSupportError.unsafeDestination("Choose a valid filename ending in .pdf.")
        }
        guard filename.utf8.count <= 255 else {
            throw PDFSupportError.unsafeDestination("The filename is too long for this folder.")
        }
        let originalDestination = try inspectDestination(url: destination, sourceIdentity: source.identity)
        let manager = FileManager.default
        // Foundation's replacement directory is on the destination volume and participates in
        // sandbox safe-save handling. A Save panel grants a file, not arbitrary sibling files.
        let replacementDirectory: URL
        do {
            replacementDirectory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: destination, create: true)
        } catch {
            throw PDFSupportError.writeFailed("A safe working location could not be created. \(error.localizedDescription)")
        }
        defer { try? manager.removeItem(at: replacementDirectory) }
        let temporaryURL = replacementDirectory.appendingPathComponent("rotated.pdf")
        let temporaryDescriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard temporaryDescriptor >= 0 else {
            throw PDFSupportError.writeFailed("The selected folder is not writable.")
        }
        close(temporaryDescriptor)

        guard let document = PDFDocument(url: source.snapshotURL) else { throw PDFSupportError.unreadablePDF }
        if document.isLocked, let password = source.password { _ = document.unlock(withPassword: password) }
        guard !document.isEncrypted else { throw PDFSupportError.encryptedExportUnsupported }
        for (index, delta) in rotations {
            guard index >= 0, index < document.pageCount, delta % 90 == 0,
                  let page = document.page(at: index) else { throw PDFSupportError.invalidRotation }
            let normalizedDelta = ((delta % 360) + 360) % 360
            page.rotation = (page.rotation + normalizedDelta) % 360
        }
        // Keep native PDF text, vector content, images, annotations and their appearance streams.
        let options: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: false, .optimizeImagesForScreenOption: false,
            .burnInAnnotationsOption: false, .saveTextFromOCROption: false
        ]
        guard document.write(to: temporaryURL, withOptions: options),
              let written = PDFDocument(url: temporaryURL), written.pageCount == document.pageCount else {
            throw PDFSupportError.writeFailed("PDFKit could not produce a complete PDF. The destination was not changed.")
        }
        for index in rotations.keys {
            guard written.page(at: index)?.rotation == document.page(at: index)?.rotation else {
                throw PDFSupportError.writeFailed("The saved page rotations could not be verified. The destination was not changed.")
            }
        }
        let finishedDescriptor = open(temporaryURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard finishedDescriptor >= 0 else { throw PDFSupportError.writeFailed("The working file became unavailable.") }
        let syncResult = fsync(finishedDescriptor)
        close(finishedDescriptor)
        guard syncResult == 0 else { throw PDFSupportError.writeFailed("The storage device could not finish writing the file.") }
        var coordinationError: NSError?
        var saveError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: .forReplacing,
                                                       error: &coordinationError) { coordinatedDestination in
            do {
                try verifySource(source)
                try verifyDestinationIsNotSource(coordinatedDestination, source: source)
                let latestDestination = try inspectDestination(url: coordinatedDestination, sourceIdentity: source.identity)
                guard latestDestination == originalDestination else {
                    throw PDFSupportError.unsafeDestination("Another operation changed this destination. Please choose Save As again.")
                }
                // No existing PDF is opened for writing. A verified complete file replaces the
                // authorized destination atomically; a new destination must still be absent.
                if originalDestination == nil {
                    try manager.moveItem(at: temporaryURL, to: coordinatedDestination)
                } else {
                    _ = try manager.replaceItemAt(coordinatedDestination, withItemAt: temporaryURL,
                                                  backupItemName: nil, options: [.usingNewMetadataOnly])
                }
            } catch { saveError = error }
        }
        if let saveError = saveError as? PDFSupportError { throw saveError }
        if let error = saveError ?? coordinationError {
            throw PDFSupportError.writeFailed(error.localizedDescription)
        }
    }

    private static func verifySource(_ source: LoadedPDF) throws {
        guard let current = try? FileIdentity.capture(url: source.sourceURL), current == source.identity else {
            throw PDFSupportError.sourceChanged
        }
    }

    private static func verifyDestinationIsNotSource(_ destination: URL, source: LoadedPDF) throws {
        let canonical = destination.resolvingSymlinksInPath().standardizedFileURL
        guard destination.standardizedFileURL != source.sourceURL, canonical != source.canonicalSourceURL,
              canonical != source.sourceURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw PDFSupportError.originalOverwriteForbidden
        }
    }

    private static func inspectDestination(url: URL, sourceIdentity: FileIdentity) throws -> FileIdentity? {
        var information = stat()
        guard fstatat(AT_FDCWD, url.path, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw PDFSupportError.unsafeDestination("The destination cannot be inspected safely.")
        }
        let identity = FileIdentity(information)
        if identity.isSameFile(as: sourceIdentity) { throw PDFSupportError.originalOverwriteForbidden }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw PDFSupportError.unsafeDestination("Choose a regular file; folders and symbolic links cannot be replaced.")
        }
        return identity
    }
}

enum PDFSortOrder: String, CaseIterable {
    case filename, creationDate

    var title: String {
        switch self {
        case .filename: return "Filename (A–Z)"
        case .creationDate: return "Creation date & time"
        }
    }

    var navigationHint: String {
        switch self {
        case .filename: return "Left: previous filename. Right: next filename."
        case .creationDate: return "Left: newer PDF. Right: older PDF. Matching timestamps use filename order; unavailable timestamps appear last."
        }
    }

    static func load(defaults: UserDefaults = .standard) -> PDFSortOrder {
        defaults.string(forKey: "pdfSortOrder").flatMap(Self.init(rawValue:)) ?? .filename
    }

    func save(defaults: UserDefaults = .standard) {
        // This preference contains no filenames, paths, timestamps or permissions.
        defaults.set(rawValue, forKey: "pdfSortOrder")
    }
}

struct FolderPDF: Sendable {
    let url: URL
    let creationDate: Date?
    let identity: FileIdentity?
}

enum FolderCatalog {
    /// Immediate readable PDF files, including .PDF; no recursive traversal, packages, or symbolic links.
    static func scanEntries(url: URL) async throws -> [FolderPDF] {
        try await backgroundWork {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isReadableKey]
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            return files.compactMap { candidate in
                guard candidate.pathExtension.lowercased() == "pdf",
                      let values = try? candidate.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      values.isPackage != true, values.isReadable != false else { return nil }
                // Read the original file's full filesystem timestamp, never the snapshot's
                // timestamp or PDF authoring metadata. Optional metadata failure cannot
                // hide an otherwise readable PDF from the folder count.
                let created = try? candidate.resourceValues(forKeys: [.creationDateKey]).creationDate
                return FolderPDF(url: candidate.standardizedFileURL, creationDate: created,
                                 identity: try? FileIdentity.capture(url: candidate))
            }
        }
    }

    static func scan(url: URL, order: PDFSortOrder = .filename) async throws -> [URL] {
        ordered(try await scanEntries(url: url), by: order).map(\.url)
    }

    static func ordered(_ entries: [FolderPDF], by order: PDFSortOrder) -> [FolderPDF] {
        entries.sorted { lhs, rhs in
            if order == .creationDate {
                let left = validDate(lhs.creationDate), right = validDate(rhs.creationDate)
                switch (left, right) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            let comparison = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
            return comparison == .orderedSame ? lhs.url.path < rhs.url.path : comparison == .orderedAscending
        }
    }

    /// Keep a renamed open file selected without treating a replacement at its old
    /// path as that document. Multiple hard links are deliberately not guessed at.
    static func index(of url: URL, identity: FileIdentity, in entries: [FolderPDF]) -> Int? {
        let path = url.standardizedFileURL
        if let exact = entries.firstIndex(where: {
            $0.url.standardizedFileURL == path && $0.identity?.isSameFile(as: identity) == true
        }) { return exact }
        let matches = entries.indices.filter { entries[$0].identity?.isSameFile(as: identity) == true }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func validDate(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return date
    }
}

struct RecentFileEntry: Codable, Identifiable {
    let id: UUID
    let url: URL
    let bookmark: Data?
    var name: String { url.lastPathComponent }
}

@MainActor final class RecentFilesStore {
    private(set) var entries: [RecentFileEntry]
    private let defaults: UserDefaults?
    private var onChange: (([RecentFileEntry]) -> Void)?
    private let key: String

    private let makeBookmark: (URL) throws -> Data

    init(defaults: UserDefaults = .standard, key: String = "recentPDFs",
         makeBookmark: @escaping (URL) throws -> Data = {
             try $0.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                 includingResourceValuesForKeys: nil, relativeTo: nil)
         }) {
        self.defaults = defaults
        self.key = key
        self.makeBookmark = makeBookmark
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([RecentFileEntry].self, from: data) {
            entries = Array(decoded.prefix(10))
        } else { entries = [] }
    }

    /// Record only after a successful open. Remembering a file does not depend
    /// on macOS being able to grant persistent permission for it.
    init(entries: [RecentFileEntry], onChange: @escaping ([RecentFileEntry]) -> Void) {
        defaults = nil; key = ""; self.onChange = onChange
        self.entries = Array(entries.prefix(10))
        makeBookmark = { try $0.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                             includingResourceValuesForKeys: nil, relativeTo: nil) }
    }

    func restore(_ entries: [RecentFileEntry]) { self.entries = Array(entries.prefix(10)) }

    func record(url: URL, replacing id: UUID? = nil) {
        guard url.isFileURL else { return }
        let normalized = url.standardizedFileURL
        let existing = entries.first { $0.url.standardizedFileURL == normalized }
        let bookmark = (try? makeBookmark(url)) ?? existing?.bookmark
        entries.removeAll { $0.id == id || $0.url.standardizedFileURL == normalized }
        entries.insert(RecentFileEntry(id: id ?? existing?.id ?? UUID(), url: normalized, bookmark: bookmark), at: 0)
        entries = Array(entries.prefix(10))
        persist()
    }

    /// Resolve moved files when possible, otherwise try the remembered path.
    /// The caller acquires/releases access and renews the bookmark after opening.
    /// Failed attempts must not reorder, remove or overwrite history entries.
    func resolve(_ entry: RecentFileEntry) -> URL {
        guard let bookmark = entry.bookmark else { return entry.url }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                         relativeTo: nil, bookmarkDataIsStale: &stale)) ?? entry.url
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        defaults?.removeObject(forKey: key)
        onChange?(entries)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults?.set(data, forKey: key)
        onChange?(entries)
    }
}

private func backgroundWork<T>(_ operation: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do { continuation.resume(returning: try autoreleasepool(invoking: operation)) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

/// APFS can share immutable data extents immediately; other volumes use a 1 MiB streaming
/// fallback. Both paths refuse a source modified during preparation.
private func copyStableFile(from source: URL, to destination: URL) throws -> (FileIdentity, Bool) {
    let sourceDescriptor = open(source.path, O_RDONLY | O_CLOEXEC)
    guard sourceDescriptor >= 0 else { throw PDFSupportError.fileAccess("The selected PDF is unavailable or access was denied.") }
    defer { close(sourceDescriptor) }
    var before = stat()
    guard fstat(sourceDescriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
        throw PDFSupportError.fileAccess("Select a regular PDF file.")
    }
    let identity = FileIdentity(before)
    func verifyUnchangedSource() throws {
        var after = stat()
        guard fstat(sourceDescriptor, &after) == 0, FileIdentity(after) == identity,
              (try? FileIdentity.capture(url: source)) == identity else { throw PDFSupportError.sourceChanged }
    }
    // Do not clone immutable/append-only flags into the private working directory.
    let restrictedFlags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
    if before.st_flags & restrictedFlags == 0,
       fclonefileat(sourceDescriptor, AT_FDCWD, destination.path, UInt32(CLONE_NOOWNERCOPY)) == 0 {
        let cloneDescriptor = open(destination.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        var cloneInformation = stat()
        let privateClone = cloneDescriptor >= 0 && fchmod(cloneDescriptor, 0o600) == 0
            && fstat(cloneDescriptor, &cloneInformation) == 0 && cloneInformation.st_size == before.st_size
        if cloneDescriptor >= 0 { close(cloneDescriptor) }
        if privateClone {
            try verifyUnchangedSource()
            return (identity, true)
        }
        // Only this freshly-created private snapshot is removed; the pinned source is read-only.
        guard unlink(destination.path) == 0 else {
            throw PDFSupportError.fileAccess("The private working copy could not be secured.")
        }
    }
    let destinationDescriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard destinationDescriptor >= 0 else { throw PDFSupportError.fileAccess("A private working copy could not be written.") }
    defer { close(destinationDescriptor) }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_048_576, alignment: 16)
    defer { buffer.deallocate() }
    while true {
        let amount = read(sourceDescriptor, buffer, 1_048_576)
        if amount == 0 { break }
        if amount < 0 {
            if errno == EINTR { continue }
            throw PDFSupportError.fileAccess("The PDF could not be read completely.")
        }
        var written = 0
        while written < amount {
            let result = write(destinationDescriptor, buffer.advanced(by: written), amount - written)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw PDFSupportError.fileAccess("The private working copy could not be completed. Check available storage.") }
            written += result
        }
    }
    try verifyUnchangedSource()
    return (identity, false)
}
