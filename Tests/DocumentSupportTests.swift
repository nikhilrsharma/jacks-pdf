import AppKit
import PDFKit
import CoreText
import ImageIO
import Darwin

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}

private func expectFailure(_ message: String, operation: () async throws -> Void,
                           matching: (PDFSupportError) -> Bool) async throws {
    do {
        try await operation()
        throw TestFailure(description: "Expected failure: \(message)")
    } catch let error as PDFSupportError {
        try expect(matching(error), "Wrong error for \(message): \(error.localizedDescription)")
    }
}

/// No UI or persistent preferences are needed for these integration checks.
private final class MemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]
    override func data(forKey defaultName: String) -> Data? { storage[defaultName] as? Data }
    override func string(forKey defaultName: String) -> String? { storage[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { storage[defaultName] = value }
    override func removeObject(forKey defaultName: String) { storage.removeValue(forKey: defaultName) }
}

@main struct DocumentSupportTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PDFSupportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Original.pdf")
        try makePDF(at: source)
        let hardlink = directory.appendingPathComponent("Hard Link.pdf")
        try FileManager.default.linkItem(at: source, to: hardlink)
        let symlink = directory.appendingPathComponent("Symbolic Link.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        let originalBytes = try Data(contentsOf: source)
        let loaded = try await PDFLoader.load(url: source)
        try expect(loaded.document.pageCount == 3, "All source pages must load")
        try expect(loaded.byteCount == originalBytes.count, "File size must describe the original")
        let snapshotPermissions = try FileManager.default.attributesOfItem(atPath: loaded.snapshotURL.path)[.posixPermissions] as? NSNumber
        try expect(snapshotPermissions?.intValue == 0o600, "Snapshot must be private")

        try await expectFailure("original path", operation: {
            try await RotationExport.save(source: loaded, rotations: [0: 90], destinationURL: source)
        }, matching: { if case .originalOverwriteForbidden = $0 { return true }; return false })
        try await expectFailure("hard link to original", operation: {
            try await RotationExport.save(source: loaded, rotations: [0: 90], destinationURL: hardlink)
        }, matching: { if case .originalOverwriteForbidden = $0 { return true }; return false })
        try await expectFailure("symbolic link to original", operation: {
            try await RotationExport.save(source: loaded, rotations: [0: 90], destinationURL: symlink)
        }, matching: { if case .originalOverwriteForbidden = $0 { return true }; return false })
        let aliasDirectory = directory.deletingLastPathComponent().appendingPathComponent("PDFParentAlias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: aliasDirectory) }
        try await expectFailure("parent symbolic link alias of original", operation: {
            try await RotationExport.save(source: loaded, rotations: [0: 90],
                                          destinationURL: aliasDirectory.appendingPathComponent("Original.pdf"))
        }, matching: { if case .originalOverwriteForbidden = $0 { return true }; return false })
        print("PASS: original path, hard link, symlink and parent-directory alias protection")

        // UI read-only flags must never leak into the exported copy.
        loaded.document.page(at: 0)?.annotations.first?.isReadOnly = true
        let destination = directory.appendingPathComponent("Rotated.pdf")
        try await RotationExport.save(source: loaded, rotations: [0: 90, 1: 90, 2: 90], destinationURL: destination)
        guard let saved = PDFDocument(url: destination) else { throw TestFailure(description: "Export must reopen") }
        try expect(saved.pageCount == 3, "Export must preserve page count")
        try expect([0, 1, 2].map { saved.page(at: $0)!.rotation } == [90, 180, 0], "Rotation must add clockwise deltas to existing rotations")
        try expect(saved.string?.contains("Vector page 1") == true, "Selectable text must survive export")
        try expect(saved.page(at: 0)?.annotations.first?.widgetStringValue == "Original field value", "Existing field values must survive export")
        try expect(saved.page(at: 0)?.annotations.first?.isReadOnly == false, "Export must preserve original form flags")
        for index in 0..<saved.pageCount {
            guard let page = saved.page(at: index)?.pageRef else { throw TestFailure(description: "Missing PDF page reference") }
            try expect(hasFontResources(page: page), "Page \(index) must retain native vector text resources")
            try expect(!hasImageResources(page: page), "Vector pages must not be replaced by raster images")
        }
        try expect(try Data(contentsOf: source) == originalBytes, "Original bytes must be unchanged")
        try expect(try Data(contentsOf: hardlink) == originalBytes, "Original hard link must be unchanged")
        let existingDestination = directory.appendingPathComponent("Existing.pdf")
        try Data("replaceable target".utf8).write(to: existingDestination)
        try await RotationExport.save(source: loaded, rotations: [0: 180], destinationURL: existingDestination)
        try expect(PDFDocument(url: existingDestination)?.page(at: 0)?.rotation == 180, "Another existing file may be replaced")
        print("PASS: rotation, vector text, annotations, original-byte preservation and permitted replacement")

        let scannedSource = directory.appendingPathComponent("Scanned.pdf")
        try makeImagePDF(at: scannedSource)
        let scannedBytes = try Data(contentsOf: scannedSource)
        let scanned = try await PDFLoader.load(url: scannedSource)
        let scannedCopy = directory.appendingPathComponent("Scanned Rotated.pdf")
        try await RotationExport.save(source: scanned, rotations: [0: 90], destinationURL: scannedCopy)
        let sourceImages = try imageSamples(document: scanned.document)
        guard let savedScan = PDFDocument(url: scannedCopy) else { throw TestFailure(description: "Scanned export must reopen") }
        let savedImages = try imageSamples(document: savedScan)
        try expect(sourceImages.count == 1 && savedImages.count == 1, "Scanned image resources must survive export")
        try expect(sourceImages[0].width == savedImages[0].width && sourceImages[0].height == savedImages[0].height,
                   "Scanned image dimensions must not be downsampled")
        try expect(sourceImages[0].pixels == savedImages[0].pixels, "Every decoded image pixel must remain unchanged")
        try expect(savedScan.page(at: 0)?.rotation == 90, "Scanned page must rotate")
        try expect(try Data(contentsOf: scannedSource) == scannedBytes, "Scanned source bytes must remain unchanged")
        print("PASS: embedded JPEG dimensions and decoded pixel bytes preserved exactly after rotation")

        let directoryDestination = directory.appendingPathComponent("Directory.pdf")
        try FileManager.default.createDirectory(at: directoryDestination, withIntermediateDirectories: false)
        for invalid in [directoryDestination, directory.appendingPathComponent("Wrong.txt"),
                        directory.appendingPathComponent(String(repeating: "a", count: 260) + ".pdf")] {
            try await expectFailure("invalid destination", operation: {
                try await RotationExport.save(source: loaded, rotations: [0: 90], destinationURL: invalid)
            }, matching: { if case .unsafeDestination = $0 { return true }; return false })
        }
        try await expectFailure("invalid rotation", operation: {
            try await RotationExport.save(source: loaded, rotations: [0: 45], destinationURL: directory.appendingPathComponent("Invalid.pdf"))
        }, matching: { if case .invalidRotation = $0 { return true }; return false })
        let mutableSource = directory.appendingPathComponent("Mutable.pdf")
        try FileManager.default.copyItem(at: source, to: mutableSource)
        let mutableLoaded = try await PDFLoader.load(url: mutableSource)
        try Data("changed source".utf8).write(to: mutableSource)
        try await expectFailure("source changed during session", operation: {
            try await RotationExport.save(source: mutableLoaded, rotations: [0: 90], destinationURL: directory.appendingPathComponent("Stale.pdf"))
        }, matching: { if case .sourceChanged = $0 { return true }; return false })
        try expect(mutableLoaded.document.pageCount == 3, "Viewing snapshot must survive source replacement")
        let leakedTemporaryFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".jackspdf-") }
        try expect(leakedTemporaryFiles.isEmpty, "Failed exports must clean up their temporary files")
        print("PASS: invalid destinations, source-change detection and failed-export cleanup")

        let encrypted = directory.appendingPathComponent("Encrypted.pdf")
        guard let encryptable = PDFDocument(url: source), encryptable.write(to: encrypted, withOptions: [
            .ownerPasswordOption: "owner-secret", .userPasswordOption: "reader-secret"
        ]) else { throw TestFailure(description: "Encrypted fixture creation failed") }
        try await expectFailure("password required", operation: { _ = try await PDFLoader.load(url: encrypted) },
                                matching: { if case .passwordRequired = $0 { return true }; return false })
        try await expectFailure("incorrect password", operation: { _ = try await PDFLoader.load(url: encrypted, password: "wrong") },
                                matching: { if case .incorrectPassword = $0 { return true }; return false })
        let unlocked = try await PDFLoader.load(url: encrypted, password: "reader-secret")
        try expect(unlocked.document.pageCount == 3, "Encrypted PDFs must be viewable with the right password")
        try await expectFailure("encrypted export protection", operation: {
            try await RotationExport.save(source: unlocked, rotations: [0: 90], destinationURL: directory.appendingPathComponent("Unprotected.pdf"))
        }, matching: { if case .encryptedExportUnsupported = $0 { return true }; return false })
        print("PASS: password handling and encrypted-export protection")

        let catalogDirectory = directory.appendingPathComponent("Catalog")
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: false)
        for filename in ["Page 10.pdf", "Page 2.PDF", "Page 1.pdf", "Ignore.txt", ".Hidden.pdf"] {
            try Data().write(to: catalogDirectory.appendingPathComponent(filename))
        }
        try FileManager.default.createDirectory(at: catalogDirectory.appendingPathComponent("Subfolder.pdf"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: catalogDirectory.appendingPathComponent("Linked.pdf"), withDestinationURL: source)
        let catalog = try await FolderCatalog.scan(url: catalogDirectory)
        try expect(catalog.map(\.lastPathComponent) == ["Page 1.pdf", "Page 2.PDF", "Page 10.pdf"],
                   "Folder catalog must use natural filename order and only immediate visible regular PDFs")
        try await checkFolderOrdering(in: catalogDirectory)

        let defaults = MemoryDefaults()
        let store = RecentFilesStore(defaults: defaults)
        for index in 0..<12 {
            let url = directory.appendingPathComponent("Recent \(index).pdf")
            try Data().write(to: url)
            store.record(url: url)
        }
        try expect(store.entries.count == 10, "History must be limited to ten files")
        try expect(store.entries.first?.name == "Recent 11.pdf", "History must show most recent first")
        let recent = directory.appendingPathComponent("Recent 7.pdf")
        store.record(url: recent)
        try expect(store.entries.count == 10 && store.entries.first?.url == recent, "History must deduplicate reordered entries")
        let recentIDs = store.entries.map(\.id)
        PDFSortOrder.creationDate.save(defaults: defaults)
        try expect(RecentFilesStore(defaults: defaults).entries.map(\.id) == recentIDs,
                   "Changing folder sort order must not reorder or modify recent-file history")
        try expect(store.resolve(store.entries[0]).standardizedFileURL == recent.standardizedFileURL, "Recent bookmarks must resolve")
        try expect(RecentFilesStore(defaults: defaults).entries.count == 10, "Recent history must survive store recreation")
        store.clear()
        try expect(store.entries.isEmpty && RecentFilesStore(defaults: defaults).entries.isEmpty, "Clear history must remove persisted entries")
        try expect(PDFSortOrder.load(defaults: defaults) == .creationDate,
                   "Clearing file history must not reset the harmless sorting preference")
        print("PASS: natural folder order, recent-file bookmarks, ten-item limit and clearing")

        // Permission failure must not make successfully viewed files disappear.
        let noAccessDefaults = MemoryDefaults()
        let noAccess = RecentFilesStore(defaults: noAccessDefaults, makeBookmark: { _ in
            throw CocoaError(.fileReadNoPermission)
        })
        for index in 0..<12 {
            noAccess.record(url: directory.appendingPathComponent("Remembered \(index).pdf"))
        }
        try expect(noAccess.entries.count == 10 && noAccess.entries.first?.name == "Remembered 11.pdf",
                   "Bookmark failures must still retain the newest ten file records")
        try expect(noAccess.entries.allSatisfy { $0.bookmark == nil }, "Permission-less records must remain usable")
        let reloaded = RecentFilesStore(defaults: noAccessDefaults)
        try expect(reloaded.entries.count == 10, "Metadata-only history must persist across relaunches")
        let missing = reloaded.entries[0]
        try expect(reloaded.resolve(missing) == missing.url && reloaded.entries[0].id == missing.id,
                   "Missing permission must fall back without discarding or reordering history")
        let replacement = noAccess.entries[3].url
        noAccess.record(url: replacement, replacing: missing.id)
        try expect(noAccess.entries.count == 9 && noAccess.entries.first?.url == replacement,
                   "Locating a moved file must replace its old entry and deduplicate the destination")
        noAccess.remove(id: missing.id)
        try expect(noAccess.entries.count == 8 && !noAccess.entries.contains { $0.id == missing.id },
                   "Removing history must remove only the selected reference")
        try expect(RecentFilesStore(defaults: noAccessDefaults).entries.count == 8,
                   "Removing a reference must persist")
        noAccess.clear()
        try expect(RecentFilesStore(defaults: noAccessDefaults).entries.isEmpty,
                   "Clearing metadata-only history must persist")

        // Previous versions stored a required Data bookmark. Optional bookmarks
        // must decode those entries without losing existing history.
        let legacyDefaults = MemoryDefaults()
        let legacyID = UUID()
        let legacy = [["id": legacyID.uuidString, "url": source.absoluteString,
                       "bookmark": Data([0, 1, 2]).base64EncodedString()]]
        legacyDefaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "recentPDFs")
        let legacyStore = RecentFilesStore(defaults: legacyDefaults)
        try expect(legacyStore.entries.count == 1 && legacyStore.entries[0].id == legacyID,
                   "Existing history must migrate without losing entries")
        try expect(legacyStore.resolve(legacyStore.entries[0]) == source,
                   "An expired or invalid bookmark must fall back to the recorded path")
        try expect(legacyStore.entries.count == 1, "Resolution failure must keep the history entry")
        legacyStore.record(url: source)
        try expect(legacyStore.entries.count == 1 && legacyStore.entries[0].id == legacyID,
                   "Successful reopening must renew access without duplicating history")
        try expect(legacyStore.entries[0].bookmark != Data([0, 1, 2]), "Successful reopening must replace an invalid bookmark")
        print("PASS: permission-independent history, migration, recovery, deduplication and removal")

        var disposable: LoadedPDF? = try await PDFLoader.load(url: source)
        let disposablePath = disposable!.snapshotURL.deletingLastPathComponent().path
        disposable = nil
        try expect(!FileManager.default.fileExists(atPath: disposablePath), "A released document must remove its private snapshot")
        print("PASS: snapshot lifetime cleanup")
        if ProcessInfo.processInfo.environment["PDF_LARGE_SNAPSHOT_TEST"] == "1" {
            try await checkLargeSnapshot(in: directory)
        }
        print("All DocumentSupport checks passed.")
    }

    private static func checkFolderOrdering(in directory: URL) async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ name: String, _ offset: TimeInterval?) -> FolderPDF {
            FolderPDF(url: directory.appendingPathComponent(name),
                      creationDate: offset.map { base.addingTimeInterval($0) }, identity: nil)
        }
        func names(_ entries: [FolderPDF], _ order: PDFSortOrder) -> [String] {
            FolderCatalog.ordered(entries, by: order).map { $0.url.lastPathComponent }
        }
        let precise = [entry("First alphabetically.pdf", 0.10), entry("Last alphabetically.pdf", 0.90),
                       entry("Middle alphabetically.pdf", 0.50)]
        try expect(names(precise, .creationDate) == ["Last alphabetically.pdf", "Middle alphabetically.pdf", "First alphabetically.pdf"],
                   "Creation order must retain fractional seconds within the same second")
        let tied = [entry("File 10.pdf", 1), entry("File 2.pdf", 1), entry("File 1.pdf", 1)]
        try expect(names(tied, .creationDate) == ["File 1.pdf", "File 2.pdf", "File 10.pdf"],
                   "Equal creation timestamps must break ties with natural filename ordering")
        let missing = [entry("Unknown 10.pdf", nil), entry("Known older.pdf", -100), entry("Unknown 2.pdf", nil),
                       entry("Known newer.pdf", 100)]
        try expect(names(missing, .creationDate) == ["Known newer.pdf", "Known older.pdf", "Unknown 2.pdf", "Unknown 10.pdf"],
                   "Unknown timestamps must remain included after dated files, in natural filename order")
        let invalid = [FolderPDF(url: directory.appendingPathComponent("Unknown 1.pdf"),
                                 creationDate: Date(timeIntervalSinceReferenceDate: .nan), identity: nil),
                       FolderPDF(url: directory.appendingPathComponent("Unknown 3.pdf"),
                                 creationDate: Date(timeIntervalSinceReferenceDate: .infinity), identity: nil),
                       entry("Known.pdf", 0), entry("Unknown 2.pdf", nil)]
        try expect(names(invalid, .creationDate) == ["Known.pdf", "Unknown 1.pdf", "Unknown 2.pdf", "Unknown 3.pdf"],
                   "Invalid dates must behave like missing dates without breaking sorting")
        let caseVariants = [entry("a 2.pdf", nil), entry("A 2.pdf", nil), entry("a 10.pdf", nil)]
        let stableNames = names(caseVariants, .filename)
        try expect(stableNames == names(Array(caseVariants.reversed()), .filename)
                   && stableNames.last == "a 10.pdf", "Natural comparison ties must resolve deterministically")
        try expect(names([], .creationDate).isEmpty && names([entry("Only.pdf", nil)], .creationDate) == ["Only.pdf"],
                   "Empty and single-file folders must sort safely")

        let defaults = MemoryDefaults()
        try expect(PDFSortOrder.load(defaults: defaults) == .filename, "New users must retain natural filename order")
        PDFSortOrder.creationDate.save(defaults: defaults)
        try expect(PDFSortOrder.load(defaults: defaults) == .creationDate, "The selected order must survive preference reload")
        PDFSortOrder.filename.save(defaults: defaults)
        try expect(PDFSortOrder.load(defaults: defaults) == .filename, "Switching back to filename order must persist")
        defaults.set("unknown-future-order", forKey: "pdfSortOrder")
        try expect(PDFSortOrder.load(defaults: defaults) == .filename, "Unknown preferences must fall back safely")
        defaults.set(123, forKey: "pdfSortOrder")
        try expect(PDFSortOrder.load(defaults: defaults) == .filename, "Malformed preferences must fall back safely")
        print("PASS: full-precision creation order, deterministic natural ties, missing/invalid dates and preference persistence")

        // Give actual files different creation and modification rankings. These are
        // test-owned files only; the production scan must never modify timestamps.
        let creationOffsets: [(String, TimeInterval, TimeInterval)] = [
            ("Page 1.pdf", 30, 100), ("Page 2.PDF", 10, 300), ("Page 10.pdf", 20, 200)
        ]
        for (name, created, modified) in creationOffsets {
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(modified),
                                                    .creationDate: base.addingTimeInterval(created)],
                                                   ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        let entries = try await FolderCatalog.scanEntries(url: directory)
        try expect(entries.count == 3 && entries.allSatisfy { $0.identity != nil && $0.creationDate != nil },
                   "Filesystem scanning must read creation timestamps and identity for eligible files")
        try expect(names(entries, .creationDate) == ["Page 1.pdf", "Page 10.pdf", "Page 2.PDF"],
                   "Creation ordering must use filesystem creation time, not modification time")
        let datedURLs = try await FolderCatalog.scan(url: directory, order: .creationDate)
        try expect(datedURLs.map(\.lastPathComponent) == ["Page 1.pdf", "Page 10.pdf", "Page 2.PDF"],
                   "Compatibility URL scan must honor the requested ordering")
        for (name, created, _) in creationOffsets {
            let values = try directory.appendingPathComponent(name).resourceValues(forKeys: [.creationDateKey])
            try expect(values.creationDate == base.addingTimeInterval(created), "Scanning must leave source creation timestamps unchanged")
        }

        let original = directory.appendingPathComponent("Page 2.PDF")
        let originalIdentity = try FileIdentity.capture(url: original)
        try expect(FolderCatalog.index(of: original, identity: originalIdentity, in: entries) != nil,
                   "Current document must be located by exact path and identity")
        let renamed = directory.appendingPathComponent("Renamed.pdf")
        try FileManager.default.moveItem(at: original, to: renamed)
        let renamedEntries = try await FolderCatalog.scanEntries(url: directory)
        let renamedIndex = FolderCatalog.index(of: original, identity: originalIdentity, in: renamedEntries)
        try expect(renamedIndex.map { renamedEntries[$0].url == renamed } == true,
                   "Renaming the current PDF must preserve its selection by filesystem identity")
        try Data("replacement".utf8).write(to: original)
        let replacedEntries = try await FolderCatalog.scanEntries(url: directory)
        let retainedIndex = FolderCatalog.index(of: original, identity: originalIdentity, in: replacedEntries)
        try expect(retainedIndex.map { replacedEntries[$0].url == renamed } == true,
                   "A replacement at the old pathname must not be mistaken for the open document")
        let linked = directory.appendingPathComponent("Another Name.pdf")
        try FileManager.default.linkItem(at: renamed, to: linked)
        let linkedEntries = try await FolderCatalog.scanEntries(url: directory)
        try expect(FolderCatalog.index(of: original, identity: originalIdentity, in: linkedEntries) == nil,
                   "Ambiguous renamed hard links must not silently select a different folder entry")
        let exactLink = FolderCatalog.index(of: renamed, identity: originalIdentity, in: linkedEntries)
        try expect(exactLink.map { linkedEntries[$0].url == renamed } == true,
                   "An exact path remains unambiguous even when another hard link exists")
        try FileManager.default.removeItem(at: renamed)
        try FileManager.default.removeItem(at: linked)
        let deletedEntries = try await FolderCatalog.scanEntries(url: directory)
        try expect(FolderCatalog.index(of: original, identity: originalIdentity, in: deletedEntries) == nil,
                   "A deleted open file must not match its replacement")
        print("PASS: real creation-time scan, unchanged source timestamps, rename retention, replacement and hard-link ambiguity")
    }

    private static func checkLargeSnapshot(in directory: URL) async throws {
        let source = directory.appendingPathComponent("Large Snapshot.pdf")
        try makePDF(at: source)
        let base = try Data(contentsOf: source)
        let baseText = String(decoding: base, as: UTF8.self)
        guard let xrefText = baseText.components(separatedBy: "startxref\n").last,
              let previousXref = Int(xrefText.components(separatedBy: "\n")[0]) else {
            throw TestFailure(description: "Large fixture needs a valid original cross-reference")
        }
        let handle = try FileHandle(forWritingTo: source)
        let objectOffset = try handle.seekToEnd()
        let paddingBytes = 200 * 1_048_576
        try handle.write(contentsOf: Data("12 0 obj\n<< /Length \(paddingBytes) >>\nstream\n".utf8))
        let sampleOffset = try handle.offset()
        let chunk = Data(repeating: 65, count: 1_048_576)
        for _ in 0..<200 { try handle.write(contentsOf: chunk) }
        try handle.write(contentsOf: Data("\nendstream\nendobj\n".utf8))
        let xrefOffset = try handle.offset()
        let entry = String(format: "%010llu 00000 n \n", objectOffset)
        try handle.write(contentsOf: Data("xref\n12 1\n\(entry)trailer\n<< /Size 13 /Root 1 0 R /Prev \(previousXref) >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        try handle.close()
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let started = Date()
        let loaded = try await PDFLoader.load(url: source)
        let elapsed = Date().timeIntervalSince(started)
        getrusage(RUSAGE_SELF, &after)
        try expect(loaded.document.pageCount == 3 && loaded.byteCount > 200 * 1_048_576, "Large PDF snapshot must remain readable")
        let mutable = try FileHandle(forWritingTo: source)
        try mutable.seek(toOffset: sampleOffset)
        try mutable.write(contentsOf: Data("changed".utf8))
        try mutable.close()
        let snapshot = try FileHandle(forReadingFrom: loaded.snapshotURL)
        try snapshot.seek(toOffset: sampleOffset)
        let copiedBytes = try snapshot.read(upToCount: 7)
        try snapshot.close()
        try expect(copiedBytes == Data(repeating: 65, count: 7), "Snapshot data must remain independent after an in-place source edit")
        let memoryGrowth = Double(max(0, after.ru_maxrss - before.ru_maxrss)) / 1_048_576
        print(String(format: "PASS: 200 MiB snapshot; copy-on-write=%@, %.3f s load, %.1f MiB peak-RSS growth; later source edit isolated",
                     loaded.snapshotUsesCopyOnWrite ? "true" : "false", elapsed, memoryGrowth))
    }

    private static func makePDF(at url: URL) throws {
        func stream(_ operations: String, additionalEntries: String = "") -> String {
            "<< /Length \(operations.utf8.count) \(additionalEntries) >>\nstream\n\(operations)endstream"
        }
        let appearance = "q 1 1 1 rg 0 0 300 32 re f Q\n/Tx BMC q BT /F1 12 Tf 0 g 2 10 Td (Original field value) Tj ET Q EMC\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [10 0 R] /NeedAppearances false /DA (/F1 12 Tf 0 g) /DR << /Font << /F1 9 0 R >> >> >> >>",
            "<< /Type /Pages /Count 3 /Kids [3 0 R 5 0 R 7 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 9 0 R >> >> /Contents 4 0 R /Annots [10 0 R] >>",
            stream("0.15 G 2 w 60 60 492 672 re S\nBT /F1 24 Tf 90 680 Td (Vector page 1) Tj ET\n"),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 9 0 R >> >> /Contents 6 0 R /Rotate 90 >>",
            stream("0.15 G 2 w 60 60 492 672 re S\nBT /F1 24 Tf 90 680 Td (Vector page 2) Tj ET\n"),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 9 0 R >> >> /Contents 8 0 R /Rotate 270 >>",
            stream("0.15 G 2 w 60 60 492 672 re S\nBT /F1 24 Tf 90 680 Td (Vector page 3) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (test-field) /V (Original field value) /Ff 0 /F 4 /Rect [90 520 390 552] /P 3 0 R /DA (/F1 12 Tf 0 g) /AP << /N 11 0 R >> >>",
            stream(appearance, additionalEntries: "/Type /XObject /Subtype /Form /BBox [0 0 300 32] /Resources << /Font << /F1 9 0 R >> >>")
        ]
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xrefOffset = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        try pdf.write(to: url)
    }

    private static func hasFontResources(page: CGPDFPage) -> Bool {
        var resources: CGPDFDictionaryRef?
        var fonts: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(page.dictionary!, "Resources", &resources)
            && CGPDFDictionaryGetDictionary(resources!, "Font", &fonts)
            && CGPDFDictionaryGetCount(fonts!) > 0
    }

    private static func hasImageResources(page: CGPDFPage) -> Bool {
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(page.dictionary!, "Resources", &resources),
              CGPDFDictionaryGetDictionary(resources!, "XObject", &objects) else { return false }
        var imageFound = false
        CGPDFDictionaryApplyFunction(objects!, { _, object, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(CGPDFStreamGetDictionary(stream)!, "Subtype", &subtype),
               let subtype, String(cString: subtype) == "Image" {
                info!.assumingMemoryBound(to: Bool.self).pointee = true
            }
        }, &imageFound)
        return imageFound
    }

    private struct ImageSample {
        let width: Int
        let height: Int
        let pixels: Data
    }

    /// The fixture embeds a real JPEG stream directly, so the test detects unintended JPEG
    /// recompression as well as downsampling instead of only checking the page's screenshot.
    private static func makeImagePDF(at url: URL) throws {
        let width = 128, height = 96
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                rgba[offset] = UInt8((x * 13 + y * 7) % 256)
                rgba[offset + 1] = UInt8((x * 5 + y * 11) % 256)
                rgba[offset + 2] = UInt8((x ^ y) * 2)
            }
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw TestFailure(description: "Could not create raster test image")
        }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else {
            throw TestFailure(description: "Could not create JPEG encoder")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.83] as CFDictionary)
        try expect(CGImageDestinationFinalize(destination), "JPEG fixture must encode")
        let jpegData = jpeg as Data
        var pdf = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets = [Int](repeating: 0, count: 6)
        func addObject(_ index: Int, _ body: Data) {
            offsets[index] = pdf.count
            pdf.append(Data("\(index) 0 obj\n".utf8))
            pdf.append(body)
            pdf.append(Data("\nendobj\n".utf8))
        }
        addObject(1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        addObject(2, Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8))
        addObject(3, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 256 192] /Resources << /XObject << /Image0 5 0 R >> >> /Contents 4 0 R >>".utf8))
        let operators = "q\n256 0 0 192 0 0 cm\n/Image0 Do\nQ\n"
        addObject(4, Data("<< /Length \(operators.utf8.count) >>\nstream\n\(operators)endstream".utf8))
        var imageObject = Data("<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpegData.count) >>\nstream\n".utf8)
        imageObject.append(jpegData)
        imageObject.append(Data("\nendstream".utf8))
        addObject(5, imageObject)
        let xrefOffset = pdf.count
        pdf.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        pdf.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        try pdf.write(to: url)
    }

    private static func imageSamples(document: PDFDocument) throws -> [ImageSample] {
        var samples: [ImageSample] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.pageRef else { continue }
            var resources: CGPDFDictionaryRef?
            var objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(page.dictionary!, "Resources", &resources),
                  CGPDFDictionaryGetDictionary(resources!, "XObject", &objects) else { continue }
            var streams: [CGPDFStreamRef] = []
            withUnsafeMutablePointer(to: &streams) { pointer in
                CGPDFDictionaryApplyFunction(objects!, { _, object, info in
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
                    var subtype: UnsafePointer<CChar>?
                    if CGPDFDictionaryGetName(CGPDFStreamGetDictionary(stream)!, "Subtype", &subtype),
                       let subtype, String(cString: subtype) == "Image" {
                        info!.assumingMemoryBound(to: [CGPDFStreamRef].self).pointee.append(stream)
                    }
                }, UnsafeMutableRawPointer(pointer))
            }
            for stream in streams {
                let dictionary = CGPDFStreamGetDictionary(stream)!
                var width = 0, height = 0, bits = 0
                try expect(CGPDFDictionaryGetInteger(dictionary, "Width", &width), "Image needs width")
                try expect(CGPDFDictionaryGetInteger(dictionary, "Height", &height), "Image needs height")
                try expect(CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits) && bits == 8, "Image must retain 8-bit components")
                var format: CGPDFDataFormat = .raw
                guard let streamData = CGPDFStreamCopyData(stream, &format) else { throw TestFailure(description: "Image stream must be readable") }
                let image: CGImage?
                if format == .raw {
                    image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 3,
                                    bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [],
                                    provider: CGDataProvider(data: streamData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                } else {
                    image = CGImageSourceCreateWithData(streamData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                }
                guard let image else { throw TestFailure(description: "Embedded image must decode") }
                var pixels = Data(count: width * height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw TestFailure(description: "Pixel comparison context could not be created")
                    }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                samples.append(ImageSample(width: width, height: height, pixels: pixels))
            }
        }
        return samples
    }
}
