import AppKit
import PDFKit
import QuartzCore

/// PDFKit supplies vector rendering; this boundary owns all document interaction.
/// No annotations or form flags are changed to make the displayed file read-only.
final class ReaderPDFView: PDFView {
    var onNavigateFile: ((Int) -> Void)?
    var onPageChanged: ((Int, Int) -> Void)?
    var onZoomChanged: ((Double, Bool) -> Void)?
    private(set) var isFit = true

    var currentPageIndex: Int {
        guard let document, let page = activePage else { return 0 }
        let index = document.index(for: page)
        return index == NSNotFound ? 0 : index
    }

    // PDFKit chooses a viewport page, which need not be the page the user clicked.
    private var clickedPage: PDFPage?
    private var activePage: PDFPage? { rotationAnchorPage ?? clickedPage ?? currentPage }
    private var activePageOutline: CAShapeLayer?
    private var focusClipBounds: CGRect?
    private var focusLayoutDepth = 0
    private var fitReferencePage: PDFPage?
    private var lastFitWidth: CGFloat = 0
    private var applyingScale = false
    private var notifications: [NSObjectProtocol] = []
    private var scrollTimer: Timer?
    private var scrollTarget: CGFloat?
    private var lastScrollTime: CFTimeInterval = 0
    private var selectionStart: (PDFPage, NSPoint)?
    // Read at each click, so changing the system preference takes effect immediately.
    var prefersReducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var rotationOverlay: CALayer?
    private var rotationSnapshots: [Int: RotationSnapshot] = [:]
    private var rotationQueue: [RotationStep] = []
    private var rotationIsPlaying = false
    private var rotationLayoutDepth = 0
    private var rotationViewport = CGRect.zero
    private var rotationClipBounds = CGRect.zero
    private var rotationLiveScale: CGFloat = 1
    private var rotationAnchorPage: PDFPage?
    private var observedClip: NSClipView?
    private var clipObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var animationGeneration = UUID()
    static let rotationDuration: TimeInterval = 0.6

    override var document: PDFDocument? {
        didSet {
            if oldValue !== document {
                clickedPage = nil
                focusClipBounds = nil
                activePageOutline?.removeFromSuperlayer()
                activePageOutline = nil
                removeRotationAnimation()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displayBox = .cropBox
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1)
        interpolationQuality = .high
        pageShadowsEnabled = true
        autoScales = false
        minScaleFactor = 0.01
        maxScaleFactor = 64
        acceptsDraggedFiles = false
        enableDataDetectors = false
        wantsLayer = true
        layer?.masksToBounds = true
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityLabel("PDF document")
        notifications.append(NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: self, queue: .main
        ) { [weak self] _ in self?.reportPage() })
        notifications.append(NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: self, queue: .main
        ) { [weak self] _ in
            guard let self, !self.applyingScale else { return }
            if self.rotationOverlay != nil, abs(self.scaleFactor - self.rotationLiveScale) > 0.0001 {
                self.removeRotationAnimation()
            }
            self.onZoomChanged?(Double(self.scaleFactor * 100), self.isFit)
        })
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.prefersReducedMotion() else { return }
            self.removeRotationAnimation()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        scrollTimer?.invalidate()
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }

    func show(document: PDFDocument, resetZoom: Bool) {
        stopSmoothScroll()
        removeRotationAnimation()
        selectionStart = nil
        clearSelection()
        self.document = document
        fitReferencePage = document.page(at: 0)
        lastFitWidth = 0
        if resetZoom { isFit = true }
        configureScrollView()
        layoutDocumentView()
        if isFit { applyFit(preservePosition: false) }
        if let first = document.page(at: 0) { go(to: first) }
        scrollToTop()
        reportPage()
        onZoomChanged?(Double(scaleFactor * 100), isFit)
        // PDFKit may finish installing its clip view on the next run-loop turn.
        DispatchQueue.main.async { [weak self, weak document] in
            guard let self, let document, self.document === document else { return }
            self.configureScrollView()
            if self.isFit { self.applyFit(preservePosition: false) }
            self.scrollToTop()
        }
    }

    func setFit() {
        let chosenPage = rotationAnchorPage ?? clickedPage
        focusLayoutDepth += 1
        defer { finishFocusLayout() }
        removeRotationAnimation()
        guard document != nil else { return }
        stopSmoothScroll()
        isFit = true
        fitReferencePage = chosenPage ?? currentPage ?? document?.page(at: 0)
        applyFit(preservePosition: chosenPage == nil)
        if let chosenPage { revealPageTop(chosenPage) }
        reportPage()
    }

    func setManualZoom(percent: Double) {
        focusLayoutDepth += 1
        defer { finishFocusLayout() }
        removeRotationAnimation()
        guard document != nil, percent.isFinite else { return }
        stopSmoothScroll()
        isFit = false
        let normalized = min(200, max(20, (percent / 5).rounded(.toNearestOrAwayFromZero) * 5))
        applyScale(CGFloat(normalized / 100), preservePosition: clickedPage == nil)
        if let clickedPage { revealPageTop(clickedPage) }
        reportPage()
    }

    override func layout() {
        focusLayoutDepth += 1
        defer { finishFocusLayout() }
        if rotationOverlay != nil, rotationLayoutDepth == 0, bounds != rotationViewport {
            removeRotationAnimation()
        }
        super.layout()
        guard isFit, !applyingScale, document != nil else { return }
        let width = viewportWidth
        if width > 0, abs(width - lastFitWidth) > 0.5 {
            applyFit(preservePosition: true)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // Expose read-only page text instead of PDFKit's actionable widget descendants.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityValue() -> Any? { activePage?.string ?? "" }

    // PDFKit's private subviews can activate form editors before PDFView.mouseDown.
    // Route content events here; native scrollbars still get their normal hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var ancestor: NSView? = hit
        while let view = ancestor, view !== self {
            if view is NSScroller { return hit }
            ancestor = view.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let wasAnimating = rotationOverlay != nil
        // Hit-test what is actually visible before dismissing a queued rotation.
        let animatedPage = wasAnimating ? rotatingPage(at: viewPoint) : nil
        removeRotationAnimation()
        stopSmoothScroll()
        selectionStart = nil
        let hitPage = wasAnimating ? animatedPage : page(for: viewPoint, nearest: false)
        guard let page = hitPage, wasAnimating || pageRect(page).contains(viewPoint) else {
            clearSelection()
            return
        }
        clickedPage = page
        focusClipBounds = readerScrollView?.contentView.bounds
        reportPage()
        // Page choice is independent of copying permission and never activates forms.
        guard !wasAnimating, document?.allowsCopying == true else { clearSelection(); return }
        let point = convert(viewPoint, to: page)
        selectionStart = (page, point)
        if event.clickCount >= 3 {
            currentSelection = page.selectionForLine(at: point)
        } else if event.clickCount == 2 {
            currentSelection = page.selectionForWord(at: point)
        } else {
            clearSelection()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (startPage, startPoint) = selectionStart, let document,
              document.allowsCopying else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let endPage = page(for: viewPoint, nearest: true) else { return }
        currentSelection = document.selection(from: startPage, at: startPoint,
                                               to: endPage, at: convert(viewPoint, to: endPage))
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) { selectionStart = nil }
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func quickLook(with event: NSEvent) {}
    override func perform(_ action: PDFAction) {}
    override func printView(_ sender: Any?) {}
    override func print(with printInfo: NSPrintInfo, autoRotate: Bool) {}
    override func print(with printInfo: NSPrintInfo, autoRotate: Bool, pageScaling: PDFPrintScalingMode) {}

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil)
            case "a": if document?.allowsCopying == true { selectAll(nil) }
            default: break
            }
            return
        }
        guard modifiers.intersection([.control, .option]).isEmpty else { return }
        switch event.keyCode {
        case 123: onNavigateFile?(-1)
        case 124: onNavigateFile?(1)
        case 125: scrollByArrow(direction: 1)
        case 126: scrollByArrow(direction: -1)
        case 116: scrollSmoothly(by: -bounds.height * 0.85)
        case 121: scrollSmoothly(by: bounds.height * 0.85)
        case 53: clearSelection()
        default: break // Tab, text input, and PDF form shortcuts cannot enter an editor.
        }
    }

    override func scrollWheel(with event: NSEvent) {
        removeRotationAnimation()
        stopSmoothScroll()
        readerScrollView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        // Keep trackpad gestures proportional while using the same five-percent policy.
        setManualZoom(percent: Double(scaleFactor * 100) * (1 + Double(event.magnification)))
    }

    override func zoomIn(_ sender: Any?) { setManualZoom(percent: Double(scaleFactor * 100) + 5) }
    override func zoomOut(_ sender: Any?) { setManualZoom(percent: Double(scaleFactor * 100) - 5) }

    func scrollByArrow(direction: Int) {
        guard direction != 0 else { return }
        scrollSmoothly(by: CGFloat(direction) * 68)
    }

    /// The document changes synchronously; only its temporary presentation is queued.
    /// Every click receives a full quarter-turn, even when clicks arrive mid-animation.
    func rotate(pageIndices: [Int]) {
        guard let document else { return }
        let indices = Set(pageIndices.filter { (0..<document.pageCount).contains($0) })
        guard !indices.isEmpty else { return }
        stopSmoothScroll()
        let reduceMotion = prefersReducedMotion()
        if reduceMotion { removeRotationAnimation() }
        let anchorPage = activePage
        focusLayoutDepth += 1
        defer { finishFocusLayout() }
        if !reduceMotion, rotationOverlay == nil {
            beginRotationPresentation(anchorPage: anchorPage)
        }
        // Bounds notifications from our own layout/anchor restoration are not user scrolling.
        rotationLayoutDepth += 1
        defer { rotationLayoutDepth -= 1 }
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (page.rotation + 90) % 360
        }
        layoutDocumentView()
        if isFit {
            fitReferencePage = anchorPage ?? document.page(at: 0)
            applyFit(preservePosition: false)
        }
        // PDFDestination points are expressed in page coordinates. Reusing one after
        // rotation can place the next page in the viewport, so restore the active
        // page's visual top instead of a rotation-dependent point inside that page.
        if let anchorPage { revealPageTop(anchorPage) }
        reportPage()
        if rotationOverlay != nil {
            enqueueRotation(indices: indices)
        }
    }

    private var readerScrollView: NSScrollView? {
        if let scroll = documentView?.enclosingScrollView { return scroll }
        return subviews.compactMap { $0 as? NSScrollView }.first
    }

    private var viewportWidth: CGFloat { readerScrollView?.contentSize.width ?? bounds.width }

    private func configureScrollView() {
        guard let scroll = readerScrollView else { return }
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = backgroundColor
        scroll.verticalScrollElasticity = .automatic
        scroll.horizontalScrollElasticity = .none
        if observedClip !== scroll.contentView {
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            observedClip = scroll.contentView
            scroll.contentView.postsBoundsChangedNotifications = true
            clipObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.updateFocusAfterViewportChange()
                guard self.rotationLayoutDepth == 0, self.rotationOverlay != nil,
                      let bounds = self.observedClip?.bounds else { return }
                // PDFKit can deliver our own layout notifications later in the run loop.
                // Cancel only if the viewport actually moved away from the recorded pose.
                if abs(bounds.minX - self.rotationClipBounds.minX) > 0.5 ||
                   abs(bounds.minY - self.rotationClipBounds.minY) > 0.5 ||
                   abs(bounds.width - self.rotationClipBounds.width) > 0.5 ||
                   abs(bounds.height - self.rotationClipBounds.height) > 0.5 {
                    self.removeRotationAnimation()
                }
            }
        }
    }

    private func applyFit(preservePosition: Bool) {
        guard !applyingScale, let page = fitReferencePage ?? currentPage ?? document?.page(at: 0) else { return }
        let pageBounds = page.bounds(for: displayBox)
        let sideways = abs(page.rotation % 180) == 90
        let pageWidth = sideways ? pageBounds.height : pageBounds.width
        let available = max(1, viewportWidth - pageBreakMargins.left - pageBreakMargins.right - 4)
        guard pageWidth > 0, available > 0 else { return }
        lastFitWidth = viewportWidth
        applyScale(available / pageWidth, preservePosition: preservePosition)
    }

    private func applyScale(_ factor: CGFloat, preservePosition: Bool) {
        guard factor.isFinite, factor > 0, !applyingScale else { return }
        applyingScale = true
        defer {
            applyingScale = false
            focusClipBounds = readerScrollView?.contentView.bounds
            updateActivePageOutline()
        }
        let destination = preservePosition ? positionAnchor() : nil
        autoScales = false
        scaleFactor = min(64, max(0.01, factor))
        layoutDocumentView()
        if let destination { go(to: destination) }
        if isFit, let page = fitReferencePage ?? currentPage { centerHorizontally(on: page) }
        onZoomChanged?(Double(scaleFactor * 100), isFit)
    }

    private func revealPageTop(_ page: PDFPage) {
        go(to: page)
        guard let scroll = readerScrollView else { return }
        let clip = scroll.contentView
        let rect = pageRect(page)
        let pageTop = isFlipped ? rect.minY : rect.maxY
        let viewportTop = isFlipped ? bounds.minY + pageBreakMargins.top : bounds.maxY - pageBreakMargins.top
        let actual = clip.convert(CGPoint(x: rect.midX, y: pageTop), from: self)
        let desired = clip.convert(CGPoint(x: bounds.midX, y: viewportTop), from: self)
        var newBounds = clip.bounds
        newBounds.origin.y += actual.y - desired.y
        let constrained = clip.constrainBoundsRect(newBounds)
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: constrained.minY))
        scroll.reflectScrolledClipView(clip)
        if isFit { centerHorizontally(on: page) }
    }

    private func centerHorizontally(on page: PDFPage) {
        guard let scroll = readerScrollView else { return }
        let clip = scroll.contentView
        let rect = pageRect(page)
        let center = clip.convert(CGPoint(x: rect.midX, y: rect.midY), from: self)
        var newBounds = clip.bounds
        newBounds.origin.x = center.x - newBounds.width / 2
        let constrained = clip.constrainBoundsRect(newBounds)
        clip.scroll(to: CGPoint(x: constrained.minX, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
    }

    private func positionAnchor() -> PDFDestination? {
        guard let destination = currentDestination, let page = destination.page else { return nil }
        let anchor = PDFDestination(page: page, at: destination.point)
        anchor.zoom = kPDFDestinationUnspecifiedValue
        return anchor
    }

    private func reportPage() {
        updateActivePageOutline()
        onPageChanged?(document == nil ? 0 : currentPageIndex + 1, document?.pageCount ?? 0)
    }

    private func finishFocusLayout() {
        focusLayoutDepth -= 1
        focusClipBounds = readerScrollView?.contentView.bounds
        updateActivePageOutline()
    }

    private func updateFocusAfterViewportChange() {
        guard let bounds = readerScrollView?.contentView.bounds else { return }
        let previous = focusClipBounds
        if clickedPage != nil, focusLayoutDepth == 0, !applyingScale, rotationLayoutDepth == 0,
           let previous {
            if abs(bounds.minX - previous.minX) > 0.5 || abs(bounds.minY - previous.minY) > 0.5 {
                // Compare cumulative movement, including slow subpixel scrolling.
                // Layout, zoom and rotation retain the choice; blocked scrolling
                // changes nothing.
                clickedPage = nil
                focusClipBounds = bounds
                reportPage()
            } else {
                updateActivePageOutline()
            }
        } else {
            focusClipBounds = bounds
            updateActivePageOutline()
        }
    }

    private func updateActivePageOutline() {
        guard let page = clickedPage, let document, document.index(for: page) != NSNotFound,
              let host = layer else {
            activePageOutline?.removeFromSuperlayer()
            activePageOutline = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let outline = activePageOutline ?? CAShapeLayer()
        if activePageOutline == nil {
            outline.name = "reader.activePage.outline"
            outline.zPosition = 0.5 // Above PDFKit, below the rotation presentation.
            outline.fillColor = nil
            outline.lineWidth = 1.5
            host.addSublayer(outline)
            activePageOutline = outline
        }
        outline.frame = bounds
        outline.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        outline.path = CGPath(rect: pageRect(page).insetBy(dx: -2, dy: -2), transform: nil)
        outline.isHidden = rotationOverlay != nil
    }

    private func rotatingPage(at point: CGPoint) -> PDFPage? {
        guard let overlay = rotationOverlay else { return nil }
        let presentation = overlay.presentation() ?? overlay
        var hit = presentation.hitTest(point)
        // The positioning wrappers have transparent rectangular bounds. Only
        // the visible, transformed paper is a page hit during the animation.
        guard hit?.name == "reader.rotation.paper" else { return nil }
        while let current = hit, current !== presentation {
            if let name = current.name, name.hasPrefix("reader.rotation.page."),
               let index = Int(name.dropFirst("reader.rotation.page.".count)) {
                return rotationSnapshots[index]?.page
            }
            hit = current.superlayer
        }
        return nil
    }

    private func scrollToTop() {
        guard let scroll = readerScrollView, let content = scroll.documentView else { return }
        let clip = scroll.contentView
        let y = content.isFlipped ? content.bounds.minY : max(content.bounds.minY, content.bounds.maxY - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    private func scrollSmoothly(by delta: CGFloat) {
        removeRotationAnimation()
        guard let scroll = readerScrollView, let content = scroll.documentView else { return }
        let clip = scroll.contentView
        // PDFKit centres a short document with a negative clip origin. There is
        // nothing to scroll in this case; clamping to zero would move the pages.
        guard content.bounds.height > clip.bounds.height + 0.5 else { return }
        let minimum = content.bounds.minY
        let maximum = max(minimum, content.bounds.maxY - clip.bounds.height)
        let signedDelta = content.isFlipped ? delta : -delta
        scrollTarget = min(maximum, max(minimum, (scrollTarget ?? clip.bounds.minY) + signedDelta))
        guard scrollTimer == nil else { return }
        lastScrollTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.advanceScroll() }
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceScroll() {
        guard let target = scrollTarget, let scroll = readerScrollView else { stopSmoothScroll(); return }
        let now = CACurrentMediaTime()
        let elapsed = min(0.05, max(0.001, now - lastScrollTime))
        lastScrollTime = now
        let clip = scroll.contentView
        let distance = target - clip.bounds.minY
        let finished = abs(distance) < 0.3
        let position = finished ? target : clip.bounds.minY + distance * CGFloat(1 - exp(-elapsed * 22))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: position))
        scroll.reflectScrolledClipView(clip)
        if finished { stopSmoothScroll() }
    }

    private func stopSmoothScroll() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollTarget = nil
    }

    private final class RotationSnapshot {
        let page: PDFPage
        let positionLayer: CALayer
        let tiltLayer: CALayer
        let paperLayer: CALayer
        let originalSize: CGSize
        let pixels: Int
        var angle: CGFloat
        var queuedAngle: CGFloat
        var scale: CGFloat = 1

        init(page: PDFPage, position: CALayer, tilt: CALayer, paper: CALayer,
             size: CGSize, pixels: Int, angle: CGFloat) {
            self.page = page
            positionLayer = position
            tiltLayer = tilt
            paperLayer = paper
            originalSize = size
            self.pixels = pixels
            self.angle = angle
            queuedAngle = angle
        }
    }

    private struct RotationTarget {
        let center: CGPoint
        let scale: CGFloat
        let angle: CGFloat
    }

    private struct RotationStep {
        let targets: [Int: RotationTarget]
        let anchorIndex: Int?
    }

    // PDFView's native backing layer has y-up coordinates; a negative angle is clockwise.
    // Derive the sign from the view in case its coordinate convention ever changes.
    private var clockwiseQuarterTurn: CGFloat { isFlipped ? .pi / 2 : -.pi / 2 }
    private let rotationPixelBudget = 4_000_000
    private let maximumAnimatedPages = 64

    private func pageRect(_ page: PDFPage) -> CGRect {
        convert(page.bounds(for: displayBox), from: page)
    }

    private func beginRotationPresentation(anchorPage: PDFPage?) {
        guard let host = layer, !visiblePages.isEmpty,
              visiblePages.count <= maximumAnimatedPages else { return }
        let overlay = CALayer()
        overlay.name = "reader.rotation.overlay"
        // AppKit can reorder PDFScrollView's backing layer during PDFKit layout.
        // Keep the animated pages above it regardless of sublayer insertion order.
        overlay.zPosition = 1
        overlay.frame = bounds
        overlay.backgroundColor = backgroundColor.cgColor
        overlay.masksToBounds = true
        rotationViewport = bounds
        rotationAnchorPage = anchorPage
        rotationOverlay = overlay
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(overlay)
        let pages = visiblePages.filter { pageRect($0).intersects(bounds) }
        let totalArea = pages.reduce(CGFloat.zero) { $0 + pageRect($1).width * pageRect($1).height }
        for page in pages {
            guard let document else { break }
            let index = document.index(for: page)
            let rect = pageRect(page)
            let allocation = max(256, Int(CGFloat(rotationPixelBudget / 2) * rect.width * rect.height / max(1, totalArea)))
            guard let snapshot = makeRotationSnapshot(page: page, index: index, rect: rect,
                                                       allocation: allocation, angle: 0) else {
                removeRotationAnimation()
                break
            }
            rotationSnapshots[index] = snapshot
        }
        CATransaction.commit()
    }

    private func makeRotationSnapshot(page: PDFPage, index: Int, rect: CGRect,
                                      allocation: Int, angle: CGFloat) -> RotationSnapshot? {
        guard let overlay = rotationOverlay, rect.width > 0, rect.height > 0,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        // These rasters exist only during the turn. PDFKit and Save As retain vector data.
        let ratio = min(1, 1600 / max(rect.width, rect.height),
                        sqrt(CGFloat(allocation) / (rect.width * rect.height)))
        let width = max(1, Int(rect.width * ratio))
        let height = max(1, Int(rect.height * ratio))
        let thumbnail = page.thumbnail(of: NSSize(width: width, height: height), for: displayBox)
        var proposed = CGRect(x: 0, y: 0, width: width, height: height)
        guard let sourceImage = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let position = CALayer()
        position.name = "reader.rotation.page.\(index)"
        position.bounds = CGRect(origin: .zero, size: rect.size)
        position.position = CGPoint(x: rect.midX, y: rect.midY)
        let tilt = CALayer()
        tilt.frame = position.bounds
        let paper = CALayer()
        paper.name = "reader.rotation.paper"
        paper.frame = position.bounds
        paper.contents = image
        paper.contentsGravity = .resize
        paper.backgroundColor = NSColor.white.cgColor
        paper.shadowColor = NSColor.black.cgColor
        paper.shadowOpacity = 0.20
        paper.shadowRadius = 9
        paper.shadowOffset = CGSize(width: 0, height: -3)
        paper.shadowPath = CGPath(rect: paper.bounds, transform: nil)
        paper.setValue(angle, forKeyPath: "transform.rotation.z")
        tilt.addSublayer(paper)
        position.addSublayer(tilt)
        overlay.addSublayer(position)
        return RotationSnapshot(page: page, position: position, tilt: tilt, paper: paper,
                                size: rect.size, pixels: width * height, angle: angle)
    }

    private func enqueueRotation(indices: Set<Int>) {
        guard let document, rotationOverlay != nil else { return }
        rotationClipBounds = readerScrollView?.contentView.bounds ?? .zero
        rotationLiveScale = scaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // A rotation/Fit may reveal more pages. Include those too, starting just outside
        // the viewport; their thumbnail's orientation is reversed for this initial pose.
        let newPages = visiblePages.filter { rotationSnapshots[document.index(for: $0)] == nil && pageRect($0).intersects(bounds) }
        guard rotationSnapshots.count + newPages.count <= maximumAnimatedPages else {
            removeRotationAnimation(); return
        }
        let remaining = rotationPixelBudget - rotationSnapshots.values.reduce(0) { $0 + $1.pixels }
        guard newPages.isEmpty || remaining >= newPages.count * 256 else {
            removeRotationAnimation(); return
        }
        for page in newPages {
            let index = document.index(for: page)
            let rect = pageRect(page)
            let initialAngle = indices.contains(index) ? -clockwiseQuarterTurn : 0
            guard let snapshot = makeRotationSnapshot(page: page, index: index, rect: rect,
                                                       allocation: remaining / max(1, newPages.count),
                                                       angle: initialAngle) else {
                removeRotationAnimation(); return
            }
            let edge = rect.midY < bounds.midY ? bounds.minY : bounds.maxY
            let offset = max(rect.width, rect.height) / 2 + 24
            snapshot.positionLayer.position.y = edge + (edge == bounds.minY ? -offset : offset)
            rotationSnapshots[index] = snapshot
        }
        var targets: [Int: RotationTarget] = [:]
        for (index, snapshot) in rotationSnapshots {
            if indices.contains(index) { snapshot.queuedAngle += clockwiseQuarterTurn }
            let rect = pageRect(snapshot.page)
            let quarterTurns = Int((snapshot.queuedAngle / clockwiseQuarterTurn).rounded())
            let basisWidth = abs(quarterTurns % 2) == 1 ? snapshot.originalSize.height : snapshot.originalSize.width
            targets[index] = RotationTarget(center: CGPoint(x: rect.midX, y: rect.midY),
                                             scale: rect.width / max(1, basisWidth),
                                             angle: snapshot.queuedAngle)
        }
        let anchorIndex = rotationAnchorPage.map { document.index(for: $0) }
        rotationQueue.append(RotationStep(targets: targets, anchorIndex: anchorIndex))
        if !rotationIsPlaying { playNextRotation() }
    }

    private func playNextRotation() {
        guard rotationOverlay != nil, !rotationQueue.isEmpty else {
            removeRotationAnimation(); return
        }
        if prefersReducedMotion() { removeRotationAnimation(); return }
        rotationIsPlaying = true
        let step = rotationQueue.removeFirst()
        let generation = animationGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            // Follow Core Animation's actual completion, including its initial commit,
            // so a queued click never cuts the preceding turn short.
            DispatchQueue.main.async {
                guard let self, self.animationGeneration == generation else { return }
                self.playNextRotation()
            }
        }
        for (index, target) in step.targets {
            guard let snapshot = rotationSnapshots[index] else { continue }
            let startCenter = snapshot.positionLayer.position
            var middleCenter = CGPoint(x: (startCenter.x + target.center.x) / 2,
                                       y: (startCenter.y + target.center.y) / 2)
            var middleScale = min(snapshot.scale, target.scale)
            let turning = abs(target.angle - snapshot.angle) > 0.01
            if turning, index == step.anchorIndex {
                // Bring the current page fully into view at mid-turn when space permits.
                let diagonal = hypot(snapshot.originalSize.width, snapshot.originalSize.height)
                middleScale = min(middleScale, max(0.01, min(bounds.width, bounds.height) - 40) / diagonal)
                middleCenter = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            let movement = CAKeyframeAnimation(keyPath: "position")
            movement.values = [NSValue(point: startCenter), NSValue(point: middleCenter), NSValue(point: target.center)]
            movement.keyTimes = [0, 0.5, 1]
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [snapshot.scale, middleScale, target.scale]
            scale.keyTimes = [0, 0.5, 1]
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = snapshot.angle
            turn.toValue = target.angle
            // Scalar endpoints are deliberately never reduced modulo 2π.
            snapshot.positionLayer.position = target.center
            snapshot.positionLayer.setValue(target.scale, forKeyPath: "transform.scale")
            snapshot.paperLayer.setValue(target.angle, forKeyPath: "transform.rotation.z")
            for animation in [movement, scale, turn] {
                animation.duration = Self.rotationDuration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            snapshot.positionLayer.add(movement, forKey: "pagePosition")
            snapshot.positionLayer.add(scale, forKey: "pageScale")
            snapshot.paperLayer.add(turn, forKey: "clockwiseTurn")
            if turning {
                var perspective = CATransform3DIdentity
                perspective.m34 = -1 / 1600
                perspective = CATransform3DRotate(perspective, 0.07, 1, 0, 0)
                perspective = CATransform3DRotate(perspective, -0.09, 0, 1, 0)
                let tilt = CAKeyframeAnimation(keyPath: "transform")
                tilt.values = [NSValue(caTransform3D: CATransform3DIdentity),
                               NSValue(caTransform3D: perspective), NSValue(caTransform3D: CATransform3DIdentity)]
                tilt.keyTimes = [0, 0.5, 1]
                tilt.duration = Self.rotationDuration
                tilt.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                snapshot.tiltLayer.add(tilt, forKey: "gentlePerspective")
                let shadow = CAKeyframeAnimation(keyPath: "shadowOpacity")
                shadow.values = [0.20, 0.34, 0.20]
                shadow.keyTimes = [0, 0.5, 1]
                shadow.duration = Self.rotationDuration
                shadow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                snapshot.paperLayer.add(shadow, forKey: "liftedShadow")
            }
            snapshot.angle = target.angle
            snapshot.scale = target.scale
        }
        CATransaction.commit()
    }

    private func removeRotationAnimation() {
        let hadRotation = rotationOverlay != nil || rotationAnchorPage != nil
        animationGeneration = UUID()
        rotationOverlay?.removeFromSuperlayer()
        rotationOverlay = nil
        rotationSnapshots.removeAll()
        rotationQueue.removeAll()
        rotationIsPlaying = false
        rotationAnchorPage = nil
        if hadRotation { reportPage() }
    }
}
