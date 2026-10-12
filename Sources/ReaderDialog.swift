import AppKit

/// App-owned sheets use the same typography as the reader. System file pickers
/// remain native panels, while long explanatory text scrolls within this sheet.
@MainActor
final class ReaderDialog: NSObject {
    var messageText = ""
    var informativeText = ""
    var headingIcon: NSImage?
    var leadingDelimiter: String?
    var sectionDelimiter: String?
    var closingText = ""
    var accessoryView: NSView?
    var textAlignment: NSTextAlignment = .left
    var photograph: NSImage?
    var fitsContentWithoutScrolling = false
    let window: NSPanel

    private var titles: [String] = []
    private var hasBuilt = false
    private var isPresented = false
    private var isEnding = false

    override init() {
        let panel = ReaderDialogPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 190),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.animationBehavior = .alertPanel
        window = panel
        super.init()
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onAccept = { [weak self] in self?.finish(.alertFirstButtonReturn) }
    }

    func addButton(withTitle title: String) { titles.append(title) }

    func beginSheetModal(for parent: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            beginSheetModal(for: parent) { continuation.resume(returning: $0) }
        }
    }

    func beginSheetModal(for parent: NSWindow,
                         completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !isPresented else { completionHandler(.abort); return }
        if !hasBuilt { build(for: parent) }
        isPresented = true
        isEnding = false
        // Keep this dialog alive while AppKit owns the sheet, including callers
        // whose local dialog variable has gone out of scope.
        parent.beginSheet(window) { [self] response in
            window.orderOut(nil)
            isPresented = false
            completionHandler(response)
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        finish(NSApplication.ModalResponse(rawValue: sender.tag))
    }

    private func cancel() {
        let cancelIndex = titles.lastIndex { $0.caseInsensitiveCompare("Cancel") == .orderedSame }
            ?? max(0, titles.count - 1)
        finish(NSApplication.ModalResponse(rawValue: 1000 + cancelIndex))
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard isPresented, !isEnding, let parent = window.sheetParent else { return }
        isEnding = true
        parent.endSheet(window, returnCode: response)
    }

    private func build(for parent: NSWindow) {
        hasBuilt = true
        if titles.isEmpty { titles = ["OK"] }
        window.title = messageText
        let screenFrame = (parent.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = max(340, min(480, parent.frame.width - 40, screenFrame.width - 80))
        let textWidth = width - 32
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = fitsContentWithoutScrolling ? 4 : 10
        stack.distribution = .fill

        var heights: [CGFloat] = []
        func append(_ view: NSView, width: CGFloat, height: CGFloat) {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: width),
                view.heightAnchor.constraint(equalToConstant: height)
            ])
            heights.append(height)
        }

        if let headingIcon {
            let imageView = NSImageView()
            imageView.image = headingIcon
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.setAccessibilityLabel("Jack's PDF app icon")
            let iconSize: CGFloat = fitsContentWithoutScrolling ? 48 : 64
            append(imageView, width: iconSize, height: iconSize)
        }
        if let leadingDelimiter, !leadingDelimiter.isEmpty {
            let label = textLabel(leadingDelimiter)
            append(label, width: textWidth, height: textHeight(leadingDelimiter, width: textWidth))
        }
        if !messageText.isEmpty {
            let label = textLabel(messageText)
            append(label, width: textWidth, height: textHeight(messageText, width: textWidth))
        }
        if !informativeText.isEmpty {
            // About keeps its section dividers without full-height blank rows.
            let text = fitsContentWithoutScrolling
                ? informativeText.replacingOccurrences(of: "\n\n", with: "\n")
                : informativeText
            let label = textLabel(text)
            append(label, width: textWidth, height: textHeight(text, width: textWidth))
        }
        if let sectionDelimiter, !sectionDelimiter.isEmpty {
            let label = textLabel(sectionDelimiter)
            append(label, width: textWidth, height: textHeight(sectionDelimiter, width: textWidth))
        }
        if !closingText.isEmpty {
            let label = textLabel(closingText)
            append(label, width: textWidth, height: textHeight(closingText, width: textWidth))
        }
        if let accessoryView {
            styleControls(in: accessoryView)
            let measuredHeight = accessoryView is NSControl ? accessoryView.fittingSize.height
                : max(accessoryView.frame.height, accessoryView.fittingSize.height)
            let height = max(26, measuredHeight)
            append(accessoryView, width: textWidth, height: height)
        }
        // The original photograph is the final content item in a memorial sheet.
        if let photograph {
            let holder = NSView()
            holder.wantsLayer = true
            holder.layer?.cornerRadius = 8
            holder.layer?.masksToBounds = true
            holder.layer?.borderWidth = 1
            holder.layer?.borderColor = NSColor(calibratedWhite: 0.65, alpha: 0.4).cgColor
            holder.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
            let imageView = NSImageView()
            imageView.image = photograph
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.setAccessibilityLabel("Jack")
            holder.addSubview(imageView)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 3),
                imageView.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -3),
                imageView.topAnchor.constraint(equalTo: holder.topAnchor, constant: 3),
                imageView.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -3)
            ])
            append(holder, width: 128, height: 96)
        }
        let naturalHeight = max(1, heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * stack.spacing)
        // Long error messages retain a bounded scroll area. About measures its
        // complete compact content instead, even when the parent is short.
        let maximumContentHeight = max(220, min(parent.frame.height - 64, screenFrame.height - 96))
        let bodyHeight = fitsContentWithoutScrolling ? naturalHeight
            : min(naturalHeight, max(80, maximumContentHeight - 70))
        let topInset: CGFloat = fitsContentWithoutScrolling ? 12 : 16
        let buttonGap: CGFloat = fitsContentWithoutScrolling ? 10 : 14
        let bottomInset: CGFloat = fitsContentWithoutScrolling ? 12 : 16
        let contentHeight = bodyHeight + topInset + buttonGap + 24 + bottomInset
        let document = ReaderDialogDocumentView(frame: NSRect(x: 0, y: 0, width: textWidth, height: naturalHeight))
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let body: NSView
        var scroll: NSScrollView?
        if fitsContentWithoutScrolling {
            // No scroll view: the entire About panel is always visible.
            body = document
        } else {
            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = naturalHeight > bodyHeight
            scrollView.hasHorizontalScroller = false
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.verticalScrollElasticity = .none
            scrollView.documentView = document
            scroll = scrollView
            body = scrollView
        }
        content.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.alignment = .centerY
        var primaryButton: NSButton?
        for (index, title) in titles.enumerated().reversed() {
            let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = AppStyle.font()
            button.tag = 1000 + index
            if index == 0 { button.keyEquivalent = "\r"; primaryButton = button }
            let labelWidth = (title as NSString).size(withAttributes: [.font: AppStyle.font()]).width
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: max(64, ceil(labelWidth) + 24)),
                button.heightAnchor.constraint(equalToConstant: 24)
            ])
            buttons.addArrangedSubview(button)
        }
        content.addSubview(buttons)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: topInset),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            body.heightAnchor.constraint(equalToConstant: bodyHeight),
            buttons.topAnchor.constraint(equalTo: body.bottomAnchor, constant: buttonGap),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -bottomInset)
        ])
        window.contentView = content
        window.defaultButtonCell = primaryButton?.cell as? NSButtonCell
        window.setContentSize(NSSize(width: width, height: contentHeight))
        content.layoutSubtreeIfNeeded()
        if let scroll {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func textLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = AppStyle.font()
        label.textColor = .labelColor
        label.alignment = textAlignment
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.setAccessibilityElement(true)
        label.setAccessibilityRole(.staticText)
        return label
    }

    private func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = .byWordWrapping
        let bounds = (text as NSString).boundingRect(with: NSSize(width: max(1, width - 4), height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: AppStyle.font(), .paragraphStyle: paragraph])
        return max(20, ceil(bounds.height) + 3)
    }

    private func styleControls(in view: NSView) {
        (view as? NSControl)?.font = AppStyle.font()
        for child in view.subviews { styleControls(in: child) }
    }
}

@MainActor
private final class ReaderDialogPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onAccept: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty { onAccept?() }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p" { return true }
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onAccept?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class ReaderDialogDocumentView: NSView {
    override var isFlipped: Bool { true }
}
