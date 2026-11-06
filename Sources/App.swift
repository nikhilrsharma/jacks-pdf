import AppKit
import PDFKit
import UniformTypeIdentifiers
import Darwin

enum AppStyle {
    static let name = "Jack's PDF"
    static let textSize: CGFloat = 13
    static func font(_ size: CGFloat = textSize) -> NSFont {
        NSFont(name: "Avenir-Book", size: size) ?? NSFont(name: "Avenir", size: size) ?? NSFont.systemFont(ofSize: size)
    }
}

final class ViewerWindow: NSWindow {
    var onArrow: ((UInt16) -> Void)?
    var onReaderShortcut: ((ReaderShortcut) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           [123, 124, 125, 126].contains(event.keyCode), attachedSheet == nil {
            onArrow?(event.keyCode)
        } else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p" { return true }
        if attachedSheet == nil, let command = ReaderShortcut.command(for: event), let onReaderShortcut {
            onReaderShortcut(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

class QuietBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ResponsiveHeader: QuietBackground {
    var onWidthChange: ((CGFloat) -> Void)?
    override func layout() {
        super.layout()
        if bounds.width > 0 { onWidthChange?(bounds.width) }
    }
}

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: ViewerWindow!
    private let pdfView = ReaderPDFView(frame: .zero)
    private let zoom = ZoomControl(frame: .zero)
    private let nameField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")
    private let leadingSeparator = NSTextField(labelWithString: "•")
    private let sizeSeparator = NSTextField(labelWithString: "•")
    private let pathField = NSTextField(labelWithString: "")
    private let countButton = NSButton(title: "", target: nil, action: nil)
    private let pageSeparator = NSTextField(labelWithString: "•")
    private var folderCounterWidth: CGFloat = 112
    private let pageField = NSTextField(labelWithString: "")
    private let rotateButton = NSButton(title: "Rotate", target: nil, action: nil)
    private let rotateMenuButton = NSButton(title: "", target: nil, action: nil)
    private let emptyView = QuietBackground(frame: .zero)
    private let messageField = NSTextField(labelWithString: "Open a PDF to begin")
    private let activity = NSProgressIndicator()
    private var recentMenu = NSMenu(title: "Open Recent")
    private lazy var history = RecentFilesStore(entries: []) { [weak self] entries in
        self?.library.recentFiles = entries
        self?.persistLibrary()
    }
    private var library = LibraryContents()
    private let libraryDisk = EncryptedLibraryDisk(url: EncryptedLibraryDisk.defaultURL)
    private var storageAvailable = false
    private var persistenceTask: Task<Void, Never>?
    private var storageErrorPending: Error?
    private var storageWarningShown = false
    private var folderAccessGeneration = 0
    private var source: LoadedPDF?
    private var rotations: [Int: Int] = [:]
    private var savedRotations: [Int: Int] = [:]
    private var catalog: [URL] = []
    private var catalogEntries: [FolderPDF] = []
    private var catalogFolder: URL?
    private var catalogError: Error?
    private var catalogRefreshGeneration = 0
    private var sortOrder = PDFSortOrder.load()
    private var folderLease: URL?
    private var sourceLease: URL?
    private var isBusy = false
    private var pendingURL: URL?
    private var transitionInFlight = false
    private var queuedOpen: (url: URL, resetZoom: Bool, recentID: UUID?, askForFolder: Bool)?
    private var fullScreenTransition = false
    private var isClosing = false
    private var instanceLock: Int32 = -1
    private var duplicate = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("jacks-pdf-viewer-instance.lock")
        instanceLock = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if instanceLock >= 0 && flock(instanceLock, LOCK_EX | LOCK_NB) != 0 { duplicate = true }
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if duplicate {
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            existing?.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        reveal()
        setBusy(true)
        Task {
            await prepareLibrary()
            setBusy(false)
            if let url = pendingURL { pendingURL = nil; queuedOpen = (url, true, nil, true) }
            drainQueuedOpen()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }) else { return }
        if duplicate {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = false
            NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: config)
            return
        }
        guard window != nil else { pendingURL = url; return }
        reveal()
        requestOpen(url, resetZoom: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { reveal(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !duplicate else { return .terminateNow }
        if isBusy || transitionInFlight || window?.attachedSheet != nil { NSSound.beep(); return .terminateCancel }
        guard isDirty || persistenceTask != nil else { return .terminateNow }
        transitionInFlight = true
        Task {
            let confirmed = await confirmClosingWithRotations()
            if confirmed { await persistenceTask?.value }
            transitionInFlight = false
            NSApp.reply(toApplicationShouldTerminate: confirmed)
            if !confirmed { queuedOpen = nil }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        source = nil
        sourceLease?.stopAccessingSecurityScopedResource()
        folderLease?.stopAccessingSecurityScopedResource()
        if instanceLock >= 0 { Darwin.close(instanceLock) }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil, canStartAction, let folder = catalogFolder else { return }
        Task {
            guard canStartAction else { return }
            await refreshCatalog(folder)
        }
    }

    private var isDirty: Bool { !rotations.isEmpty && rotations != savedRotations }
    private var canStartAction: Bool { !isBusy && !transitionInFlight && !fullScreenTransition && window?.attachedSheet == nil }

    private func buildWindow() {
        window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppStyle.name
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.drainQueuedOpen() }
        }
        window.aspectRatio = NSSize(width: 16, height: 10)
        window.minSize = NSSize(width: 800, height: 500)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        window.onArrow = { [weak self] code in
            guard let self, !self.isBusy else { return }
            switch code {
            case 123: self.navigate(-1)
            case 124: self.navigate(1)
            case 125: self.pdfView.scrollByArrow(direction: 1)
            case 126: self.pdfView.scrollByArrow(direction: -1)
            default: break
            }
        }
        window.onReaderShortcut = { [weak self] command in self?.performReaderShortcut(command) }
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        addWindowName()
        sizeWindow()

        let content = QuietBackground(frame: .zero)
        window.contentView = content
        let header = makeHeader()
        [header, pdfView, emptyView, activity].forEach { content.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor), header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: header.bottomAnchor), pdfView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: content.leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: pdfView.topAnchor), emptyView.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
            emptyView.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor), emptyView.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            activity.topAnchor.constraint(equalTo: pdfView.topAnchor, constant: 12), activity.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)
        ])
        activity.style = .spinning
        activity.controlSize = .small
        activity.isDisplayedWhenStopped = false
        let welcome = NSStackView()
        welcome.orientation = .vertical
        welcome.spacing = 16
        let title = NSTextField(labelWithString: AppStyle.name)
        title.font = AppStyle.font()
        messageField.font = AppStyle.font()
        messageField.textColor = .secondaryLabelColor
        let openButton = NSButton(title: "Open PDF…", target: self, action: #selector(openPanel))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.font = AppStyle.font()
        openButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        [title, messageField, openButton].forEach { welcome.addArrangedSubview($0) }
        emptyView.addSubview(welcome)
        welcome.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([welcome.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor), welcome.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor)])

        pdfView.onNavigateFile = { [weak self] in self?.navigate($0) }
        pdfView.onPageChanged = { [weak self] page, total in
            let text = total > 0 ? "Page \(page) of \(total)" : ""
            self?.pageField.stringValue = text
            self?.pageField.toolTip = text.isEmpty ? nil : text
        }
        pdfView.onZoomChanged = { [weak self] percent, fit in self?.zoom.update(percent: percent, isFit: fit) }
        zoom.onFit = { [weak self] in self?.pdfView.setFit(); self?.focusPDF() }
        zoom.onManual = { [weak self] in self?.pdfView.setManualZoom(percent: $0); self?.focusPDF() }
        updateControls()
    }

    private func addWindowName() {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        let label = NSTextField(labelWithString: AppStyle.name)
        label.font = AppStyle.font()
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        let labelWidth = ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width)
        let icon = NSImageView()
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            icon.image = NSImage(contentsOf: iconURL)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        icon.setAccessibilityLabel("Jack's PDF app icon")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: labelWidth + 34, height: 24))
        accessory.view = container
        container.addSubview(icon)
        container.addSubview(label)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: labelWidth)
        ])
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func makeHeader() -> NSView {
        let header = ResponsiveHeader(frame: .zero)
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.135, alpha: 1).cgColor
        nameField.font = AppStyle.font()
        nameField.lineBreakMode = .byClipping
        nameField.isSelectable = true
        sizeField.font = AppStyle.font()
        sizeField.textColor = .secondaryLabelColor
        sizeField.alignment = .right
        sizeField.lineBreakMode = .byTruncatingTail
        pathField.font = AppStyle.font()
        pathField.textColor = .secondaryLabelColor
        pathField.isSelectable = true
        pathField.lineBreakMode = .byClipping
        // Only these document views grow with their text. Their fixed viewports do not.
        let nameScroll = horizontalText(nameField)
        let pathScroll = horizontalText(pathField)

        countButton.isBordered = false
        countButton.controlSize = .small
        countButton.font = AppStyle.font()
        countButton.alignment = .right
        countButton.contentTintColor = .secondaryLabelColor
        countButton.target = self
        countButton.action = #selector(showPDFOrder)
        countButton.imagePosition = .imageTrailing
        countButton.cell?.lineBreakMode = .byTruncatingMiddle
        pageField.font = AppStyle.font()
        pageField.textColor = .secondaryLabelColor
        pageField.alignment = .left
        pageField.lineBreakMode = .byTruncatingMiddle
        for separator in [leadingSeparator, sizeSeparator, pageSeparator] {
            separator.font = NSFont(name: "Avenir-Heavy", size: AppStyle.textSize)
                ?? NSFontManager.shared.convert(AppStyle.font(), toHaveTrait: .boldFontMask)
            separator.textColor = .secondaryLabelColor
            separator.alignment = .center
            separator.setAccessibilityElement(false)
            separator.isHidden = true
        }

        rotateButton.target = self
        rotateButton.action = #selector(rotateCurrent)
        rotateButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Rotate current page clockwise")
        rotateButton.imagePosition = .imageLeading
        rotateButton.alignment = .left
        rotateButton.controlSize = .small
        rotateButton.font = AppStyle.font()
        rotateButton.bezelStyle = .rounded
        rotateButton.image = rotateButton.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        rotateButton.toolTip = "Rotate the current page 90° clockwise (⌘R)"
        rotateMenuButton.target = self
        rotateMenuButton.action = #selector(showRotateMenu)
        rotateMenuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Rotation options")
        rotateMenuButton.bezelStyle = .rounded
        rotateMenuButton.controlSize = .small
        rotateMenuButton.image = rotateMenuButton.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular))

        let fixedControls = NSView()
        [leadingSeparator, sizeField, sizeSeparator, countButton, pageSeparator, pageField, rotateButton, rotateMenuButton, zoom].forEach { fixedControls.addSubview($0) }
        // Text viewports can extend into the transparent part of the controls group.
        // Keep them above that container so their full visible width accepts scrolling.
        [fixedControls, nameScroll, pathScroll].forEach { header.addSubview($0) }
        let headerHeight = header.heightAnchor.constraint(equalToConstant: 76)
        headerHeight.isActive = true
        header.onWidthChange = { [weak self, weak header] width in
            guard let self, let header else { return }
            let compact = width < 1000
            headerHeight.constant = compact ? 134 : 76
            let margin: CGFloat = 16
            let controlsWidth: CGFloat = 718
            let controlsX = width - margin - controlsWidth
            // The main control anchors depend on window width alone. Metadata reserves
            // the widest index in the folder so navigation cannot shift its right edges.
            fixedControls.frame = NSRect(x: controlsX, y: compact ? 12 : 14,
                                         width: controlsWidth, height: 48)
            let countX = 240 - self.folderCounterWidth
            let sizeWidth = min(72, max(1, ceil(self.sizeField.cell?.cellSize.width
                                               ?? self.sizeField.intrinsicContentSize.width)))
            let sizeX = countX - 16 - sizeWidth
            self.leadingSeparator.frame = NSRect(x: sizeX - 16, y: 28, width: 16, height: 20)
            self.sizeField.frame = NSRect(x: sizeX, y: 28, width: sizeWidth, height: 20)
            self.sizeSeparator.frame = NSRect(x: countX - 16, y: 28, width: 16, height: 20)
            self.countButton.frame = NSRect(x: countX, y: 28, width: self.folderCounterWidth, height: 20)
            self.pageSeparator.frame = NSRect(x: 240, y: 28, width: 16, height: 20)
            self.pageField.frame = NSRect(x: 256, y: 28, width: 150, height: 20)
            self.rotateButton.frame = NSRect(x: 256, y: 2, width: 88, height: 24)
            self.rotateMenuButton.frame = NSRect(x: 344, y: 2, width: 20, height: 24)
            self.zoom.frame = NSRect(x: 418, y: 0, width: 300, height: 48)
            // Each text row uses all the space before its actual neighbour, rather
            // than stopping at the wide, mostly transparent controls container.
            let nameRight = compact ? width - margin : controlsX + self.leadingSeparator.frame.minX - 12
            let pathRight = compact ? width - margin : controlsX + self.rotateButton.frame.minX - 12
            nameScroll.frame = NSRect(x: margin, y: compact ? 98 : 42,
                                      width: max(1, nameRight - margin), height: 20)
            pathScroll.frame = NSRect(x: margin, y: compact ? 65 : 12,
                                      width: max(1, pathRight - margin), height: 21)
            self.zoom.needsLayout = true
            header.needsDisplay = true
        }
        return header
    }

    private func horizontalText(_ label: NSTextField) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.documentView = label
        label.sizeToFit()
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return scroll
    }

    @objc private func sizeWindow() {
        guard !fullScreenTransition, !window.styleMask.contains(.fullScreen) else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let available = screen.visibleFrame
        let width = min(available.width * 0.9, available.height * 0.9 * 1.6)
        window.setFrame(NSRect(x: available.midX - width / 2, y: available.midY - width / 3.2, width: width, height: width / 1.6), display: true)
    }
    func windowDidChangeScreen(_ notification: Notification) { sizeWindow() }
    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = true
        // Cancel the fixed aspect using AppKit's supported reset. A zero ratio
        // can produce an invalid restoration frame when leaving full screen.
        window.resizeIncrements = NSSize(width: 1, height: 1)
    }
    func windowDidEnterFullScreen(_ notification: Notification) { fullScreenTransition = false; drainQueuedOpen() }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransition = false
        window.aspectRatio = NSSize(width: 16, height: 10)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        drainQueuedOpen()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenTransition = false
        window.aspectRatio = NSSize(width: 16, height: 10)
        drainQueuedOpen()
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreenTransition = false; drainQueuedOpen() }
    private func reveal() { guard window != nil else { return }; window.deminiaturize(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); focusPDF() }
    private func focusPDF() { window?.makeFirstResponder(pdfView) }

    private func buildMenu() {
        NSMenuItem.usesUserKeyEquivalents = false
        let main = NSMenu()
        main.font = AppStyle.font()
        recentMenu.font = AppStyle.font()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            menu.font = AppStyle.font()
            item.submenu = menu; main.addItem(item); return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ selector: Selector, key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            item.target = self
            menu.addItem(item)
        }
        let app = submenu(AppStyle.name)
        add(app, "About \(AppStyle.name)", #selector(showAbout))
        add(app, "Shortcuts", #selector(showShortcuts))
        app.addItem(.separator())
        add(app, "Quit \(AppStyle.name)", #selector(quitApp), key: "q")
        let file = submenu("File")
        add(file, "Open PDF…", #selector(openPanel), key: "o")
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu; file.addItem(recent)
        file.addItem(.separator())
        add(file, "Save As…", #selector(saveAsAction), key: "s", modifiers: [.command, .shift])
        add(file, "Close PDF", #selector(closePDF))
        let view = submenu("View")
        add(view, "Full Screen", #selector(toggleFullScreen(_:)), key: "f", modifiers: [.command, .control])
        NSApp.mainMenu = main
        rebuildRecentMenu()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func toggleFullScreen(_ sender: Any?) {
        guard canStartAction else { return }
        window.toggleFullScreen(sender)
    }

    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        for entry in history.entries {
            let item = NSMenuItem(title: entry.name, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = entry.id
            item.toolTip = entry.url.path
            item.target = self
            recentMenu.addItem(item)
        }
        if history.entries.isEmpty {
            let item = NSMenuItem(title: "No Recent PDFs", action: nil, keyEquivalent: "")
            item.isEnabled = false; recentMenu.addItem(item)
        }
        if !history.entries.isEmpty || !library.folders.isEmpty {
            recentMenu.addItem(.separator())
            let item = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            item.target = self; recentMenu.addItem(item)
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFullScreen(_:)) {
            menuItem.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Full Screen"
            return canStartAction && !fullScreenTransition
        }
        if menuItem.action == #selector(saveAsAction) { return source != nil && !rotations.isEmpty && canStartAction }
        if [#selector(rotateCurrent), #selector(rotateAll), #selector(closePDF)].contains(menuItem.action) { return source != nil && canStartAction }
        return canStartAction
    }
    @objc private func openRecent(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let entry = history.entries.first(where: { $0.id == id }) else { return }
        requestOpen(history.resolve(entry), resetZoom: true, recentID: entry.id, askForFolder: false)
    }
    @objc private func clearHistory() {
        guard canStartAction else { return }
        transitionInFlight = true
        Task {
            defer { transitionInFlight = false; drainQueuedOpen() }
            let alert = ReaderDialog()
            alert.messageText = "Clear history and saved folder access?"
            alert.informativeText = "This will remove all recently opened PDFs from history and forget all folder permissions saved by Jack’s PDF. You will need to approve folder access again to browse neighbouring PDFs.\n\nYour files will not be deleted or changed."
            alert.addButton(withTitle: "Clear History and Folder Access")
            alert.addButton(withTitle: "Cancel")
            alert.defaultButtonIndex = 1
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            guard storageAvailable else {
                presentError(LibraryStorageError.missingKey)
                return
            }
            await persistenceTask?.value
            do {
                try await libraryDisk.save(LibraryContents())
                library = LibraryContents()
                storageErrorPending = nil
                history.restore([])
                folderAccessGeneration += 1
                folderLease?.stopAccessingSecurityScopedResource(); folderLease = nil
                catalog = []; catalogEntries = []; catalogError = nil; catalogFolder = nil
                rebuildRecentMenu(); updateCount(); updateControls()
            } catch { presentError(error) }
        }
    }

    private func performReaderShortcut(_ command: ReaderShortcut) {
        guard canStartAction else { return }
        if command == .closeWindow { window.performClose(nil); return }
        guard source != nil else { return }
        switch command {
        case .zoomIn: zoom.increase()
        case .zoomOut: zoom.decrease()
        case .actualSize: pdfView.setManualZoom(percent: 100); focusPDF()
        case .fit: pdfView.setFit(); focusPDF()
        case .rotateCurrent: rotateCurrent()
        case .rotateAll: rotateAll()
        case .closeWindow: break
        }
    }

    private func prepareLibrary() async {
        do {
            let legacy = FileManager.default.fileExists(atPath: EncryptedLibraryDisk.defaultURL.path)
                ? LibraryContents() : try LibraryContents.legacy(defaults: .standard)
            library = try await libraryDisk.load(migrating: legacy)
            history.restore(library.recentFiles)
            storageAvailable = true
            // Only remove old plaintext data after encrypted storage has been verified.
            UserDefaults.standard.removeObject(forKey: "recentPDFs")
            UserDefaults.standard.removeObject(forKey: "readOnlyFolders")
            rebuildRecentMenu()
        } catch { storageErrorPending = error }
    }

    private func persistLibrary() {
        guard storageAvailable else { return }
        let snapshot = library
        let previous = persistenceTask
        persistenceTask = Task {
            await previous?.value
            do { try await libraryDisk.save(snapshot) }
            catch {
                if !storageWarningShown { storageErrorPending = error }
            }
            drainQueuedOpen()
        }
    }

    private func showStorageWarning(_ error: Error) {
        storageWarningShown = true
        let alert = ReaderDialog()
        alert.messageText = "Couldn’t save or unlock private history"
        alert.informativeText = error.localizedDescription + "\n\nYou can continue reading PDFs, but recent history and folder approvals may not be saved. The app will not save this information unencrypted."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.drainQueuedOpen() }
    }

    @objc private func openPanel() {
        guard canStartAction else { return }
        reveal()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose one PDF to view."
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.requestOpen(url, resetZoom: true) }
            else { self?.drainQueuedOpen() }
        }
    }

    private func requestOpen(_ url: URL, resetZoom: Bool, recentID: UUID? = nil, askForFolder: Bool = true) {
        guard url.isFileURL else { return }
        if isBusy || transitionInFlight || fullScreenTransition || window.attachedSheet != nil {
            queuedOpen = (url, resetZoom, recentID, askForFolder)
            return
        }
        transitionInFlight = true
        Task {
            defer { transitionInFlight = false; drainQueuedOpen() }
            // Switching files treats unsaved rotations as temporary viewing state.
            // load() keeps the current document intact if the next file cannot open.
            await load(url, resetZoom: resetZoom, recentID: recentID, askForFolder: askForFolder)
        }
    }

    private func drainQueuedOpen() {
        if canStartAction, let error = storageErrorPending {
            storageErrorPending = nil; showStorageWarning(error); return
        }
        guard !isBusy, !transitionInFlight, !fullScreenTransition, window.attachedSheet == nil, let next = queuedOpen else { return }
        queuedOpen = nil
        requestOpen(next.url, resetZoom: next.resetZoom, recentID: next.recentID, askForFolder: next.askForFolder)
    }

    private func load(_ url: URL, resetZoom: Bool, recentID: UUID? = nil, askForFolder: Bool = true,
                      refreshFolder: Bool = true) async {
        guard !isBusy else { return }
        setBusy(true)
        let hasScope = url.startAccessingSecurityScopedResource()
        var password: String?
        var loaded: LoadedPDF?
        var openingError: Error?
        while loaded == nil {
            do { loaded = try await PDFLoader.load(url: url, password: password) }
            catch PDFSupportError.passwordRequired {
                password = await askPassword(url, incorrect: false)
                if password == nil { break }
            } catch PDFSupportError.incorrectPassword {
                password = await askPassword(url, incorrect: true)
                if password == nil { break }
            } catch { openingError = error; break }
        }
        guard let loaded else {
            let accessUnavailable = !FileManager.default.isReadableFile(atPath: url.path)
            if hasScope { url.stopAccessingSecurityScopedResource() }
            setBusy(false)
            if let openingError {
                if let recentID, let entry = history.entries.first(where: { $0.id == recentID }),
                   accessUnavailable {
                    await recoverRecent(entry)
                } else { presentError(openingError) }
            }
            return
        }
        sourceLease?.stopAccessingSecurityScopedResource()
        sourceLease = hasScope ? url : nil
        source = loaded
        rotations = [:]; savedRotations = [:]
        pdfView.show(document: loaded.document, resetZoom: resetZoom)
        emptyView.isHidden = true
        window.title = "\(url.lastPathComponent) — \(AppStyle.name)"
        nameField.stringValue = url.lastPathComponent
        sizeField.stringValue = ByteCountFormatter.string(fromByteCount: loaded.byteCount, countStyle: .file)
        let folderPath = url.deletingLastPathComponent().path
        pathField.stringValue = folderPath
        nameField.sizeToFit(); pathField.sizeToFit()
        sizeField.toolTip = sizeField.stringValue
        nameField.toolTip = url.lastPathComponent; pathField.toolTip = folderPath
        nameField.enclosingScrollView?.contentView.scroll(to: .zero)
        pathField.enclosingScrollView?.contentView.scroll(to: .zero)
        history.record(url: url, replacing: recentID); rebuildRecentMenu()
        setBusy(false)
        let folder = url.deletingLastPathComponent()
        if catalogFolder?.standardizedFileURL != folder.standardizedFileURL {
            catalog = []; catalogEntries = []; catalogError = nil; catalogFolder = nil
            folderLease?.stopAccessingSecurityScopedResource(); folderLease = nil
            await prepareFolder(folder, ask: askForFolder)
        } else if refreshFolder { await refreshCatalog(folder) }
        else { updateCount() }
        updateControls(); focusPDF()
    }

    private func recoverRecent(_ entry: RecentFileEntry) async {
        let alert = ReaderDialog()
        alert.messageText = "Locate this recent PDF?"
        alert.informativeText = "\(entry.name)\n\nThe file may have moved, be unavailable, or need your permission again. Select it to reopen it. Your current PDF will stay open until another PDF loads successfully."
        alert.addButton(withTitle: "Locate File…")
        alert.addButton(withTitle: "Remove from History")
        alert.addButton(withTitle: "Cancel")
        let response = await alert.beginSheetModal(for: window)
        if response == .alertSecondButtonReturn {
            history.remove(id: entry.id)
            rebuildRecentMenu()
        } else if response == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.title = "Locate Recent PDF"
            panel.message = "Select \(entry.name) to restore access, or choose its new location."
            panel.prompt = "Open PDF"
            panel.allowedContentTypes = [.pdf]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = entry.url.deletingLastPathComponent()
            panel.nameFieldStringValue = entry.name
            if await panel.beginSheetModal(for: window) == .OK, let selected = panel.url {
                await load(selected, resetZoom: true, recentID: entry.id, askForFolder: false)
            }
        }
    }

    private func askPassword(_ url: URL, incorrect: Bool) async -> String? {
        let alert = ReaderDialog()
        alert.messageText = incorrect ? "That password didn't unlock the PDF" : "This PDF is password protected"
        alert.informativeText = "Enter the password for \(url.lastPathComponent). It will not be stored in history."
        alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        field.controlSize = .small
        field.font = AppStyle.font()
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func prepareFolder(_ folder: URL, ask: Bool, useSavedAccess: Bool = true) async {
        let key = folder.standardizedFileURL.path
        if useSavedAccess, let bookmark = library.folders[key]?.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               url.resolvingSymlinksInPath().standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL,
               url.startAccessingSecurityScopedResource() {
                folderLease?.stopAccessingSecurityScopedResource()
                folderLease = url
                if stale { rememberFolder(url) }
                else { library.rememberFolder(url, bookmark: bookmark); persistLibrary() }
                await refreshCatalog(folder)
                return
            }
        }
        guard ask else { updateCount(); return }
        let panel = NSOpenPanel()
        panel.title = "Enable Navigation Between PDFs"
        panel.message = "File: \(source?.sourceURL.lastPathComponent ?? "PDF")\nFolder: \(folder.path)\n\nSelect this folder to let Jack’s PDF read it, show its PDF count, and open neighbouring PDFs with the Left and Right arrow keys.\n\nChoose Cancel to read only this PDF. Folder navigation and the folder’s PDF count will remain unavailable."
        panel.prompt = "Allow Folder Access"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.directoryURL = folder
        let response = await panel.beginSheetModal(for: window)
        if response == .OK, let selected = panel.url,
           selected.resolvingSymlinksInPath().standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL {
            _ = selected.startAccessingSecurityScopedResource()
            folderLease?.stopAccessingSecurityScopedResource()
            folderLease = selected
            rememberFolder(selected)
            await refreshCatalog(folder)
        } else { updateCount() }
    }
    private func rememberFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
            library.rememberFolder(url, bookmark: data)
            persistLibrary()
            rebuildRecentMenu()
        }
    }
    private func refreshCatalog(_ folder: URL) async {
        guard folderLease != nil else { return }
        let generation = folderAccessGeneration
        catalogRefreshGeneration += 1
        let refreshGeneration = catalogRefreshGeneration
        do {
            let entries = try await FolderCatalog.scanEntries(url: folder)
            guard folderLease != nil, generation == folderAccessGeneration,
                  refreshGeneration == catalogRefreshGeneration,
                  source?.sourceURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return }
            catalogEntries = FolderCatalog.ordered(entries, by: sortOrder)
            catalog = catalogEntries.map(\.url)
            catalogError = nil; catalogFolder = folder; updateCount()
        } catch {
            guard folderLease != nil, generation == folderAccessGeneration,
                  refreshGeneration == catalogRefreshGeneration,
                  source?.sourceURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return }
            catalog = []; catalogEntries = []; catalogError = error
            catalogFolder = folder; updateCount()
        }
    }
    @objc private func showPDFOrder() {
        guard canStartAction else { return }
        guard catalogFolder != nil else { allowFolder(); return }
        let menu = NSMenu(title: "PDF order")
        menu.font = AppStyle.font()
        for order in PDFSortOrder.allCases {
            let item = NSMenuItem(title: order.title, action: #selector(changePDFOrder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order.rawValue
            item.state = order == sortOrder ? .on : .off
            item.toolTip = order.navigationHint
            menu.addItem(item)
        }
        if catalogError != nil {
            menu.addItem(.separator())
            let retry = NSMenuItem(title: "Allow Folder Access…", action: #selector(retryFolderAccess), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: countButton)
        focusPDF()
    }
    @objc private func changePDFOrder(_ sender: NSMenuItem) {
        guard canStartAction, let raw = sender.representedObject as? String,
              let order = PDFSortOrder(rawValue: raw), order != sortOrder else { return }
        sortOrder = order
        order.save()
        // Reorder only the folder list. PDFKit, the snapshot and unsaved rotations stay intact.
        catalogEntries = FolderCatalog.ordered(catalogEntries, by: order)
        catalog = catalogEntries.map(\.url)
        updateCount()
        focusPDF()
    }
    @objc private func allowFolder() {
        guard catalogFolder == nil, let folder = source?.sourceURL.deletingLastPathComponent(), canStartAction else { return }
        transitionInFlight = true
        Task {
            defer { transitionInFlight = false; drainQueuedOpen() }
            await prepareFolder(folder, ask: true)
        }
    }
    @objc private func retryFolderAccess() {
        guard canStartAction, catalogError != nil, let folder = source?.sourceURL.deletingLastPathComponent() else { return }
        transitionInFlight = true
        folderAccessGeneration += 1
        folderLease?.stopAccessingSecurityScopedResource(); folderLease = nil
        catalog = []; catalogEntries = []; catalogError = nil; catalogFolder = nil
        updateCount()
        Task {
            defer { transitionInFlight = false; drainQueuedOpen() }
            await prepareFolder(folder, ask: true, useSavedAccess: false)
        }
    }
    private func updateCount() {
        guard let source else { countButton.title = ""; countButton.image = nil; return }
        if catalogFolder != nil {
            let index = FolderCatalog.index(of: source.sourceURL, identity: source.identity, in: catalogEntries)
            countButton.title = catalogError != nil ? "Folder unavailable" : "PDF \(index.map { String($0 + 1) } ?? "—") of \(catalog.count)"
            countButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
            countButton.setAccessibilityLabel("\(countButton.title). PDF order: \(sortOrder.title)")
            countButton.setAccessibilityHelp("Choose the order for Left and Right arrow navigation. \(sortOrder.navigationHint)")
            var detail = "\(sortOrder.title)\n\(sortOrder.navigationHint)\nClick to change PDF order."
            if catalogError != nil { detail += "\nThe folder is currently unavailable. Try again when it is accessible." }
            else if index == nil { detail += "\nThe open PDF is no longer listed in this folder. Reopen it to resume folder navigation." }
            countButton.toolTip = detail
        } else {
            countButton.image = nil
            countButton.title = "Browse folder…"
            countButton.setAccessibilityLabel("Enable folder navigation")
            countButton.setAccessibilityHelp("Allow access to this PDF's folder")
            countButton.toolTip = "Allow access to this PDF's folder"
        }
        updateFolderCounterWidth()
    }
    private func updateFolderCounterWidth() {
        if catalogFolder != nil,
           let cell = countButton.cell?.copy() as? NSButtonCell {
            // Avenir uses equal-width numerals. Measuring the last index reserves enough
            // space for every PDF in this folder, including digit-count transitions.
            let digits = String(max(1, catalog.count)).count
            cell.title = "PDF \(String(repeating: "8", count: digits)) of \(catalog.count)"
            // Include the permanent chevron, and leave room for unusually large folders.
            folderCounterWidth = min(186, max(ceil(cell.cellSize.width), ceil(countButton.intrinsicContentSize.width)))
        } else {
            folderCounterWidth = min(186, ceil(countButton.intrinsicContentSize.width))
        }
        countButton.superview?.superview?.needsLayout = true
    }
    private func navigate(_ offset: Int) {
        guard canStartAction, source != nil else { return }
        guard let folder = catalogFolder else { NSSound.beep(); return }
        transitionInFlight = true
        Task {
            defer { transitionInFlight = false; drainQueuedOpen() }
            // Reconcile external additions, renames and removals before choosing a neighbour.
            await refreshCatalog(folder)
            guard let source else { return }
            if let error = catalogError { presentError(error); return }
            guard let index = FolderCatalog.index(of: source.sourceURL, identity: source.identity, in: catalogEntries) else {
                presentError(PDFSupportError.fileAccess("The open PDF is no longer listed in this folder. Reopen it to resume folder navigation."))
                return
            }
            let next = index + offset
            guard catalog.indices.contains(next) else { return }
            await load(catalog[next], resetZoom: false, refreshFolder: false)
        }
    }

    @objc private func rotateCurrent() { rotate(indices: [pdfView.currentPageIndex]) }
    @objc private func rotateAll() {
        guard let source else { return }
        rotate(indices: Array(0..<source.document.pageCount))
    }
    private func rotate(indices: [Int]) {
        guard let source, canStartAction else { return }
        let valid = indices.filter { $0 >= 0 && $0 < source.document.pageCount }
        for index in valid {
            let value = ((rotations[index] ?? 0) + 90) % 360
            if value == 0 { rotations.removeValue(forKey: index) } else { rotations[index] = value }
        }
        pdfView.rotate(pageIndices: valid)
        updateControls(); focusPDF()
    }
    @objc private func showRotateMenu() {
        guard let source else { return }
        let menu = NSMenu()
        let current = NSMenuItem(title: "Rotate current page    ·    Page \(pdfView.currentPageIndex + 1) only", action: #selector(rotateCurrent), keyEquivalent: "r")
        current.target = self
        current.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        current.keyEquivalentModifierMask = .command
        menu.addItem(current)
        let all = NSMenuItem(title: "Rotate all pages    ·    All \(source.document.pageCount) pages", action: #selector(rotateAll), keyEquivalent: "r")
        all.target = self; all.image = current.image
        all.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(all)
        menu.font = AppStyle.font()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: rotateMenuButton.bounds.minY - 5), in: rotateMenuButton)
    }
    @objc private func saveAsAction() {
        guard canStartAction else { return }
        transitionInFlight = true
        Task {
            defer { transitionInFlight = false; drainQueuedOpen() }
            _ = await saveAs()
        }
    }
    private func saveAs() async -> Bool {
        guard let source, !isBusy, !rotations.isEmpty else { return false }
        let panel = NSSavePanel()
        panel.title = "Save Rotated PDF As"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = source.sourceURL.deletingLastPathComponent()
        panel.nameFieldStringValue = source.sourceURL.deletingPathExtension().lastPathComponent + " — rotated.pdf"
        panel.message = "To prevent accidental overwriting, original PDF is always protected. Choose a different filename."
        guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return false }
        setBusy(true)
        let scope = destination.startAccessingSecurityScopedResource()
        defer { if scope { destination.stopAccessingSecurityScopedResource() }; setBusy(false) }
        do {
            try await RotationExport.save(source: source, rotations: rotations, destinationURL: destination)
            savedRotations = rotations
            if let folder = catalogFolder { await refreshCatalog(folder) }
            return true
        } catch { presentError(error); return false }
    }
    private func confirmClosingWithRotations() async -> Bool {
        guard !isBusy else { return false }
        guard isDirty else { return true }
        let alert = ReaderDialog()
        alert.messageText = "Keep your page rotations?"
        alert.informativeText = "The original PDF has not changed. Save a rotated copy before closing."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return await saveAs()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    @objc private func closePDF() {
        guard canStartAction else { return }
        unload()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosing { return true }
        guard canStartAction else { return false }
        transitionInFlight = true
        Task {
            defer { transitionInFlight = false; drainQueuedOpen() }
            if await confirmClosingWithRotations() { unload(); isClosing = true; window.close(); isClosing = false }
        }
        return false
    }
    private func unload() {
        pdfView.document = nil
        source = nil; rotations = [:]; savedRotations = [:]
        sourceLease?.stopAccessingSecurityScopedResource(); sourceLease = nil
        folderAccessGeneration += 1
        folderLease?.stopAccessingSecurityScopedResource(); folderLease = nil
        catalog = []; catalogEntries = []; catalogError = nil; catalogFolder = nil
        nameField.stringValue = ""; pathField.stringValue = ""; sizeField.stringValue = ""; pageField.stringValue = ""; countButton.title = ""
        nameField.toolTip = nil; pathField.toolTip = nil; countButton.toolTip = nil
        sizeField.toolTip = nil; pageField.toolTip = nil
        emptyView.isHidden = false
        window.title = AppStyle.name
        updateControls()
    }
    private func setBusy(_ value: Bool) {
        isBusy = value
        if value { activity.startAnimation(nil) } else { activity.stopAnimation(nil) }
        updateControls()
    }
    private func updateControls() {
        let enabled = source != nil && !isBusy
        zoom.isEnabled = enabled
        rotateButton.isEnabled = enabled
        rotateMenuButton.isEnabled = enabled
        countButton.isEnabled = enabled
        if source == nil {
            countButton.image = nil
            countButton.setAccessibilityLabel(nil)
            countButton.setAccessibilityHelp(nil)
            folderCounterWidth = 112
        }
        leadingSeparator.isHidden = source == nil
        sizeSeparator.isHidden = source == nil
        pageSeparator.isHidden = source == nil
        rotateButton.title = isDirty ? "Rotate •" : "Rotate"
    }
    private func presentError(_ error: Error) {
        let alert = ReaderDialog()
        alert.messageText = "Couldn't complete that action"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.drainQueuedOpen() }
    }
    @objc private func showShortcuts() {
        guard canStartAction else { return }
        let alert = ReaderDialog()
        alert.fitsContentWithoutScrolling = true
        alert.messageText = "Shortcuts"
        alert.referenceRows = ShortcutReference.rows
        alert.sectionDelimiter = "• • •"
        alert.closingText = ShortcutReference.notes
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.drainQueuedOpen() }
    }

    @objc private func showAbout() {
        let alert = ReaderDialog()
        alert.fitsContentWithoutScrolling = true
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            alert.headingIcon = NSImage(contentsOf: iconURL)
        }
        alert.leadingDelimiter = "• • •"
        alert.messageText = AppStyle.name
        alert.informativeText = "• • •\n\nA private, minimal PDF viewer for Mac.\n\n• • •\n\nCreated by Nikhil Sharma\nMade with OpenAI ChatGPT models.\nLast updated: November 5, 2026\nVersion 1.9.1"
        alert.sectionDelimiter = "• • •"
        alert.closingText = "In loving memory of Jack, our sweetest companion and forever friend.\nYou are still in our hearts and our lives every day."
        alert.textAlignment = .center
        if let photoURL = Bundle.main.url(forResource: "Jack", withExtension: "jpg") {
            alert.photograph = NSImage(contentsOf: photoURL)
        }
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.drainQueuedOpen() }
    }
}
