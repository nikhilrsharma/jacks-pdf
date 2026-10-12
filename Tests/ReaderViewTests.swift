import AppKit
import CoreText
import PDFKit
import QuartzCore
import Darwin

private struct ReaderTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ReaderTestFailure(description: message) }
}

/// Native AppKit/PDFKit integration checks; uses generated pages in an unshown window.
/// Run separately from DocumentSupportTests because each executable has its own entry point.
@main
struct ReaderViewTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let reader = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 650))
        window.contentView = reader
        let document = try makePDF()
        var reportedPage = 0
        var reportedTotal = 0
        var zoomEvents = 0
        reader.onPageChanged = { reportedPage = $0; reportedTotal = $1 }
        reader.onZoomChanged = { _, _ in zoomEvents += 1 }
        if ProcessInfo.processInfo.environment["READER_PAGE_FOCUS_ONLY"] == "1" {
            try checkPageActivation(reader: reader)
            print("All focused page-activation checks passed.")
            return
        }
        reader.show(document: document, resetZoom: true)
        settle()

        let firstPage = document.page(at: 0)!
        let scroll = reader.documentView!.enclosingScrollView!
        let expectedFit = (scroll.contentSize.width - 40) / 600
        try check(reader.isFit, "A fresh open must start in Fit")
        try check(abs(reader.scaleFactor - expectedFit) < 0.01, "Fit must fill width with document margins")
        try check(reportedPage == 1 && reportedTotal == 3 && reader.currentPageIndex == 0,
                  "Page callback is one-based; currentPageIndex is zero-based")
        try check(reader.displayMode == .singlePageContinuous && reader.displayDirection == .vertical,
                  "Pages must use continuous vertical layout")
        try check(reader.displaysPageBreaks && reader.pageBreakMargins.top > 0, "Pages need visible separation")
        try check(reader.documentView!.bounds.height > scroll.contentSize.height, "Continuous content must include all pages")

        let firstFit = reader.scaleFactor
        let eventsBeforeScroll = zoomEvents
        reader.go(to: document.page(at: 1)!)
        settle()
        try check(reader.currentPageIndex == 1 && reportedPage == 2, "Scrolling/page navigation must update page information")
        try check(abs(reader.scaleFactor - firstFit) < 0.001 && zoomEvents == eventsBeforeScroll,
                  "Fit width must remain stable while moving onto an inherently rotated page")
        reader.setFit()
        let sidewaysFit = (scroll.contentSize.width - 40) / 800
        try check(abs(reader.scaleFactor - sidewaysFit) < 0.01,
                  "Explicit Fit must account for an existing 90-degree page rotation")
        print("PASS: fit-width geometry, continuous pages, current-page reporting and stable zoom during scrolling")

        reader.setManualZoom(percent: 37.4)
        try check(abs(reader.scaleFactor - 0.35) < 0.001 && !reader.isFit, "Manual zoom must snap to five-percent ticks")
        reader.setManualZoom(percent: 37.5)
        try check(abs(reader.scaleFactor - 0.40) < 0.001, "Half-ticks must round upward")
        reader.setManualZoom(percent: 500)
        try check(reader.scaleFactor == 2, "Manual zoom must clamp at 200%")
        reader.setManualZoom(percent: -1)
        try check(reader.scaleFactor == 0.2, "Manual zoom must clamp at 20%")
        reader.setManualZoom(percent: .nan)
        try check(reader.scaleFactor == 0.2, "Invalid scale input must be ignored")
        reader.setManualZoom(percent: 75)
        let nextDocument = try makePDF()
        reader.show(document: nextDocument, resetZoom: false)
        settle()
        try check(!reader.isFit && abs(reader.scaleFactor - 0.75) < 0.001,
                  "Folder navigation can retain the chosen manual zoom mode")
        reader.show(document: document, resetZoom: true)
        settle()
        try check(reader.isFit && abs(reader.scaleFactor - firstFit) < 0.01, "An explicit new open must reset Fit")
        print("PASS: five-percent rounding, manual limits and explicit versus retained zoom state")

        reader.rotate(pageIndices: [0, 0, -1, 100])
        try check(firstPage.rotation == 90, "Current-page rotation must add exactly one clockwise quarter-turn")
        try check(document.page(at: 1)!.rotation == 90 && document.page(at: 2)!.rotation == 270,
                  "Single-page rotation must preserve other page orientations")
        try check(abs(reader.scaleFactor - sidewaysFit) < 0.01, "Fit must use rotated page geometry")
        reader.rotate(pageIndices: [0])
        reader.rotate(pageIndices: [0])
        reader.rotate(pageIndices: [0])
        try check(firstPage.rotation == 0 && abs(reader.scaleFactor - firstFit) < 0.01,
                  "Four rotations must restore orientation and fit width")
        reader.rotate(pageIndices: [0, 1, 2])
        try check((0..<3).map { document.page(at: $0)!.rotation } == [90, 180, 0],
                  "Rotate all must preserve each page's pre-existing orientation offset")
        reader.setManualZoom(percent: 85)
        reader.rotate(pageIndices: [0, 1, 2])
        try check(!reader.isFit && abs(reader.scaleFactor - 0.85) < 0.001,
                  "Rotation must preserve manual zoom")
        try check(document.string?.contains("Hello reader") == true, "Rotation must retain selectable vector text")
        print("PASS: current/all-page clockwise rotation, existing rotations, full turns and preserved manual zoom")

        try checkSettledRotationPresentation(reader: reader, window: window)
        try checkRotationPresentation(reader: reader, window: window)
        try checkPageActivation(reader: reader)

        // Restore the fixture before interaction checks, with the editable flags intact.
        let interactiveDocument = try makePDF()
        reader.show(document: interactiveDocument, resetZoom: true)
        settle()
        let page = interactiveDocument.page(at: 0)!
        let textField = page.annotations.first { $0.fieldName == "unchanged-text" }!
        let checkbox = page.annotations.first { $0.fieldName == "unchanged-checkbox" }!
        let textFlags = textField.isReadOnly
        let checkboxState = checkbox.buttonWidgetState
        let fieldPoint = CGPoint(x: textField.bounds.midX, y: textField.bounds.midY)
        let fieldViewPoint = reader.convert(fieldPoint, from: page)
        try check(reader.hitTest(fieldViewPoint) === reader, "Content hit testing must not expose editable PDFKit descendants")
        reader.mouseDown(with: try mouseEvent(reader: reader, page: page, point: fieldPoint))
        reader.keyDown(with: try keyEvent(key: 0, text: "changed"))
        reader.keyDown(with: try keyEvent(key: 48, text: "\t"))
        reader.mouseUp(with: try mouseEvent(reader: reader, page: page, point: fieldPoint, type: .leftMouseUp))
        reader.mouseDown(with: try mouseEvent(reader: reader, page: page,
                                             point: CGPoint(x: checkbox.bounds.midX, y: checkbox.bounds.midY)))
        reader.mouseUp(with: try mouseEvent(reader: reader, page: page, point: fieldPoint, type: .leftMouseUp))
        try check(textField.widgetStringValue == "Original form value" && textField.isReadOnly == textFlags,
                  "Text input must not fill a field or alter its flags")
        try check(checkbox.buttonWidgetState == checkboxState && !checkbox.isReadOnly,
                  "Clicking must not toggle a checkbox or mutate its flags")
        try check(reader.accessibilityChildren()?.isEmpty == true && reader.accessibilityRole() == .staticText,
                  "Accessibility must not expose actionable form widgets")
        try check((reader.accessibilityValue() as? String)?.contains("Hello reader") == true,
                  "Current-page text must remain available to accessibility")
        reader.mouseDown(with: try mouseEvent(reader: reader, page: page, point: CGPoint(x: 80, y: 690), clicks: 2))
        try check(reader.currentSelection?.string?.contains("Hello") == true, "Plain document text must remain selectable")
        print("PASS: text fields and checkboxes remain unchanged; safe text selection and read-only accessibility")

        let oldPage = reader.currentPageIndex
        let oldScale = reader.scaleFactor
        reader.perform(PDFActionNamed(name: .nextPage))
        reader.perform(PDFActionNamed(name: .zoomIn))
        reader.perform(PDFActionNamed(name: .print))
        reader.printView(nil)
        reader.print(with: NSPrintInfo.shared, autoRotate: false)
        reader.print(with: NSPrintInfo.shared, autoRotate: true, pageScaling: .pageScaleToFit)
        reader.keyDown(with: try keyEvent(key: 35, text: "p", modifiers: .command))
        try check(reader.currentPageIndex == oldPage && reader.scaleFactor == oldScale,
                  "Embedded PDF actions must not alter navigation or zoom")
        try check(window.attachedSheet == nil && NSApp.modalWindow == nil, "No print panel may open")
        try check(reader.menu(for: try mouseEvent(reader: reader, page: page, point: fieldPoint)) == nil,
                  "No PDF context menu may expose printing, editing, sharing or properties")
        print("PASS: embedded actions, printing commands and PDF context menus are blocked")

        var fileDirections: [Int] = []
        reader.onNavigateFile = { fileDirections.append($0) }
        reader.keyDown(with: try keyEvent(key: 123))
        reader.keyDown(with: try keyEvent(key: 124))
        try check(fileDirections == [-1, 1], "Left and right arrows must request previous and next files")
        let clip = reader.documentView!.enclosingScrollView!.contentView
        let startingY = clip.bounds.minY
        for _ in 0..<4 { reader.keyDown(with: try keyEvent(key: 125, repeatKey: true)) }
        settle(0.15)
        let downY = clip.bounds.minY
        let isFlipped = reader.documentView!.isFlipped
        try check(isFlipped ? downY > startingY : downY < startingY, "Repeated Down must smoothly advance through the document")
        reader.setManualZoom(percent: Double(reader.scaleFactor * 100)) // Stop any outstanding animation.
        for _ in 0..<4 { reader.keyDown(with: try keyEvent(key: 126, repeatKey: true)) }
        settle(0.20)
        try check(isFlipped ? clip.bounds.minY < downY : clip.bounds.minY > downY, "Repeated Up must scroll toward earlier pages")
        print("PASS: file-navigation arrows and smooth repeated vertical arrows")
        print("All ReaderView checks passed.")
    }

    @MainActor private static func checkPageActivation(reader: ReaderPDFView) throws {
        let document = try makePDF()
        for index in 0..<document.pageCount { document.page(at: index)!.rotation = 0 }
        let priorCallback = reader.onPageChanged
        let priorMotionPreference = reader.prefersReducedMotion
        reader.window?.orderFrontRegardless()
        var reportedPage = 0
        var reportedTotal = 0
        reader.onPageChanged = { page, total in
            reportedPage = page
            reportedTotal = total
            priorCallback?(page, total)
        }
        defer {
            reader.onPageChanged = priorCallback
            reader.prefersReducedMotion = priorMotionPreference
            reader.window?.orderOut(nil)
        }
        reader.show(document: document, resetZoom: true)
        settle()
        reader.setManualZoom(percent: 20)
        settle(0.08)
        try check(visiblePageIndices(reader) == Set(0..<3), "The focus regression must show all three pages at 20%")
        let clip = reader.documentView!.enclosingScrollView!.contentView
        let originalBounds = clip.bounds

        for index in [1, 0, 2, 0, 2] {
            let page = document.page(at: index)!
            let point = CGPoint(x: page.bounds(for: .cropBox).midX, y: page.bounds(for: .cropBox).midY)
            reader.mouseDown(with: try mouseEvent(reader: reader, page: page, point: point))
            reader.mouseUp(with: try mouseEvent(reader: reader, page: page, point: point, type: .leftMouseUp))
            settle()
            try check(reader.currentPageIndex == index && reportedPage == index + 1 && reportedTotal == 3,
                      "Clicking fully visible page \(index + 1) must immediately activate it and report its number")
            try check(clip.bounds == originalBounds && abs(reader.scaleFactor - 0.2) < 0.001,
                      "Choosing page \(index + 1) must not scroll or zoom the document")
            try check((reader.accessibilityValue() as? String)?.contains("page \(index + 1)") == true,
                      "Accessibility must expose the clicked page, even when PDFKit chooses a different viewport page")
            try checkActiveOutline(reader, page: page)
        }

        // Clicking empty canvas is not an instruction to choose a nearby page.
        let canvasPoint = CGPoint(x: reader.bounds.minX + 2, y: reader.bounds.midY)
        try check(reader.page(for: canvasPoint, nearest: false) == nil, "Blank-click fixture must be outside every page")
        reader.mouseDown(with: try mouseEvent(reader: reader, viewPoint: canvasPoint))
        reader.mouseUp(with: try mouseEvent(reader: reader, viewPoint: canvasPoint, type: .leftMouseUp))
        settle()
        try check(reader.currentPageIndex == 2 && reportedPage == 3 && clip.bounds == originalBounds,
                  "Clicking the empty canvas must keep the explicitly chosen page and viewport")
        reader.scrollByArrow(direction: -1)
        reader.scrollByArrow(direction: 1)
        settle(0.08)
        try check(clip.bounds == originalBounds && reader.currentPageIndex == 2 && reportedPage == 3,
                  "When every page fits, blocked scroll attempts must not discard the clicked page (bounds \(originalBounds) -> \(clip.bounds), content \(reader.documentView!.bounds), active \(reader.currentPageIndex), reported \(reportedPage))")

        // The app passes currentPageIndex into Rotate; the selected third page must be its target.
        reader.prefersReducedMotion = { true }
        reader.rotate(pageIndices: [reader.currentPageIndex])
        settle()
        try check((0..<3).map { document.page(at: $0)!.rotation } == [0, 0, 90],
                  "Rotate current page must rotate the clicked third page without rotating its neighbors")
        try check(reader.currentPageIndex == 2 && reportedPage == 3 && abs(reader.scaleFactor - 0.2) < 0.001,
                  "Rotation must retain the selected page and manual zoom")
        try checkActiveOutline(reader, page: document.page(at: 2)!)
        reader.prefersReducedMotion = { false }
        reader.rotate(pageIndices: [reader.currentPageIndex])
        reader.rotate(pageIndices: [reader.currentPageIndex])
        try check(rotationOverlay(reader) != nil && document.page(at: 2)!.rotation == 270,
                  "Rapid animated rotations must both target the explicitly selected page")
        let animationDeadline = Date().addingTimeInterval(2)
        while rotationOverlay(reader) != nil && Date() < animationDeadline { settle(0.02) }
        settle()
        try check(rotationOverlay(reader) == nil && reader.currentPageIndex == 2 && reportedPage == 3 &&
                  (0..<3).map { document.page(at: $0)!.rotation } == [0, 0, 270],
                  "The active page must remain selected after its animated queue ends")
        try checkActiveOutline(reader, page: document.page(at: 2)!)
        reader.setManualZoom(percent: 25)
        settle()
        try check(reader.currentPageIndex == 2 && reportedPage == 3,
                  "Changing zoom must keep an explicitly selected page active while it remains visible")
        try checkActiveOutline(reader, page: document.page(at: 2)!)
        reader.setFit()
        settle()
        let expectedFit = (reader.documentView!.enclosingScrollView!.contentSize.width - 40) / 800
        let selectedRect = reader.convert(document.page(at: 2)!.bounds(for: .cropBox), from: document.page(at: 2)!)
        try check(reader.isFit && abs(reader.scaleFactor - expectedFit) < 0.01 && reader.currentPageIndex == 2,
                  "Fit must use the clicked page's rotated width and retain it as the active page")
        try check(selectedRect.intersection(reader.bounds).height > reader.bounds.height * 0.5,
                  "Fit must reveal a meaningful part of the selected page")
        try checkActiveOutline(reader, page: document.page(at: 2)!)

        // Slow trackpad-like motion must accumulate instead of preserving focus indefinitely.
        let beforeTinyScroll = clip.bounds.origin
        for step in 1...3 {
            clip.scroll(to: CGPoint(x: beforeTinyScroll.x, y: beforeTinyScroll.y - CGFloat(step) * 0.25))
            reader.documentView!.enclosingScrollView!.reflectScrolledClipView(clip)
            settle(0.02)
        }
        try check(activeOutline(reader.layer) == nil &&
                  reader.currentPageIndex == document.index(for: reader.currentPage!) && reportedPage == reader.currentPageIndex + 1,
                  "Repeated subpixel scroll movement must eventually release explicit focus and resume viewport reporting")
        let thirdPage = document.page(at: 2)!
        reader.mouseDown(with: try mouseEvent(reader: reader, page: thirdPage, point: CGPoint(x: 300, y: 400)))
        reader.mouseUp(with: try mouseEvent(reader: reader, page: thirdPage, point: CGPoint(x: 300, y: 400), type: .leftMouseUp))
        try check(reader.currentPageIndex == 2, "The third page must be selectable again after tiny scrolling")

        // Actual navigation away from the selected page must restore viewport-based reporting.
        for _ in 0..<30 { reader.scrollByArrow(direction: -1) }
        settle(0.55)
        reader.setManualZoom(percent: Double(reader.scaleFactor * 100)) // Finish pending smooth scrolling.
        settle()
        try check(!visiblePageIndices(reader).contains(2) && reader.currentPageIndex != 2,
                  "Scrolling away from a selected page must release its explicit focus")
        let nativeIndex = document.index(for: reader.currentPage!)
        try check(reader.currentPageIndex == nativeIndex && reportedPage == nativeIndex + 1,
                  "Once the selected page is left behind, the counter must follow the visible viewport again")

        // Activation must also work over a form, without changing the form or preventing text selection.
        reader.setManualZoom(percent: 20)
        settle()
        let firstPage = document.page(at: 0)!
        let checkbox = firstPage.annotations.first { $0.fieldName == "unchanged-checkbox" }!
        let checkboxState = checkbox.buttonWidgetState
        let point = CGPoint(x: checkbox.bounds.midX, y: checkbox.bounds.midY)
        reader.mouseDown(with: try mouseEvent(reader: reader, page: firstPage, point: point))
        reader.mouseUp(with: try mouseEvent(reader: reader, page: firstPage, point: point, type: .leftMouseUp))
        try check(reader.currentPageIndex == 0 && checkbox.buttonWidgetState == checkboxState && !checkbox.isReadOnly,
                  "A form click must focus its page without editing the checkbox or its flags")
        reader.mouseDown(with: try mouseEvent(reader: reader, page: firstPage, point: CGPoint(x: 80, y: 690), clicks: 2))
        reader.mouseUp(with: try mouseEvent(reader: reader, page: firstPage, point: CGPoint(x: 80, y: 690), type: .leftMouseUp))
        try check(reader.currentPageIndex == 0 && reader.currentSelection?.string?.contains("Hello") == true,
                  "Page activation must preserve safe double-click text selection")

        guard let restrictedData = document.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "focus-test-owner",
            PDFDocumentWriteOption.userPasswordOption: "focus-test-reader",
            PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 1 << 5)
        ]), let restricted = PDFDocument(data: restrictedData), restricted.unlock(withPassword: "focus-test-reader") else {
            throw ReaderTestFailure(description: "Could not create a copy-restricted PDF focus fixture")
        }
        try check(!restricted.allowsCopying, "Restricted fixture must prohibit copying")
        reader.show(document: restricted, resetZoom: true)
        settle()
        reader.setManualZoom(percent: 20)
        settle()
        let restrictedThird = restricted.page(at: 2)!
        reader.mouseDown(with: try mouseEvent(reader: reader, page: restrictedThird, point: CGPoint(x: 100, y: 100)))
        reader.mouseUp(with: try mouseEvent(reader: reader, page: restrictedThird, point: CGPoint(x: 100, y: 100), type: .leftMouseUp))
        try check(reader.currentPageIndex == 2 && reportedPage == 3 && reader.currentSelection == nil,
                  "Copy restrictions must not block choosing a page and must still prevent text selection")
        try checkActiveOutline(reader, page: restrictedThird)

        let replacement = try makePDF()
        reader.show(document: replacement, resetZoom: true)
        settle()
        try check(reader.currentPageIndex == 0 && reportedPage == 1 && reportedTotal == 3,
                  "Opening a different document must reset focus to its first page")
        if let outline = activeOutline(reader.layer), !outline.isHidden, outline.opacity > 0 {
            try checkActiveOutline(reader, page: replacement.page(at: 0)!)
        }

        // A click during animation must target the visible snapshot, not its final native geometry.
        reader.setManualZoom(percent: 20)
        settle()
        reader.rotate(pageIndices: [0, 1, 2])
        settle(0.15)
        guard let overlay = rotationOverlay(reader), let presentedOverlay = overlay.presentation(),
              let presentedThird = rotationPaper(overlay, index: 2)?.presentation() else {
            throw ReaderTestFailure(description: "The animated-click fixture must show the third page's presentation")
        }
        let visibleThirdCenter = presentedThird.convert(CGPoint(x: presentedThird.bounds.midX, y: presentedThird.bounds.midY),
                                                         to: presentedOverlay)
        reader.mouseDown(with: try mouseEvent(reader: reader, viewPoint: visibleThirdCenter))
        reader.mouseUp(with: try mouseEvent(reader: reader, viewPoint: visibleThirdCenter, type: .leftMouseUp))
        settle()
        try check(rotationOverlay(reader) == nil && reader.currentPageIndex == 2 && reportedPage == 3,
                  "Clicking the visible third-page snapshot must stop animation and activate that page")
        try checkActiveOutline(reader, page: replacement.page(at: 2)!)
        print("PASS: click-to-activate all visible pages, stable viewport, outline, selected-page rotation/Fit, blocked/real scrolling, animated clicks, read-only forms, copy restrictions and document reset")
    }

    private static func activeOutline(_ layer: CALayer?) -> CALayer? {
        guard let layer else { return nil }
        if layer.name == "reader.activePage.outline" { return layer }
        return layer.sublayers?.lazy.compactMap { activeOutline($0) }.first
    }

    private static func checkActiveOutline(_ reader: ReaderPDFView, page: PDFPage) throws {
        guard let root = reader.layer, let outline = activeOutline(root) else {
            throw ReaderTestFailure(description: "The active page must have a subtle visible outline")
        }
        let localRect = (outline as? CAShapeLayer)?.path?.boundingBoxOfPath ?? outline.bounds
        let outlineRect = outline.convert(localRect, to: root)
        let pageRect = reader.convert(page.bounds(for: reader.displayBox), from: page)
        try check(!outline.isHidden && outline.opacity > 0 &&
                  abs(outlineRect.midX - pageRect.midX) < 4 && abs(outlineRect.midY - pageRect.midY) < 4 &&
                  abs(outlineRect.width - pageRect.width) < 12 && abs(outlineRect.height - pageRect.height) < 12,
                  "The active-page outline must follow the chosen page's position, zoom and rotation")
    }

    @MainActor private static func checkSettledRotationPresentation(reader: ReaderPDFView, window: NSWindow) throws {
        reader.prefersReducedMotion = { false }
        window.orderFrontRegardless()
        for mode in ["Fit", "Manual", "All pages"] {
            let document = try makePDF()
            reader.show(document: document, resetZoom: true)
            settle(0.12)
            if mode == "Manual" { reader.setManualZoom(percent: 65); settle(0.08) }
            for turn in 1...8 {
                let indices = mode == "All pages" ? Array(0..<document.pageCount) : [0]
                reader.rotate(pageIndices: indices)
                guard let overlay = rotationOverlay(reader), let paper = rotationPaper(overlay, index: 0),
                      let position = overlay.sublayers?.first(where: { $0.name == "reader.rotation.page.0" }),
                      let tilt = position.sublayers?.first else {
                    throw ReaderTestFailure(description: "\(mode) settled turn \(turn) did not create its animation")
                }
                try check(paper.animation(forKey: "clockwiseTurn")?.duration == 0.6 &&
                          paper.animation(forKey: "liftedShadow")?.duration == 0.6 &&
                          tilt.animation(forKey: "gentlePerspective")?.duration == 0.6 &&
                          position.animation(forKey: "pageScale")?.duration == 0.6,
                          "\(mode) settled turn \(turn) must retain all visual effects")
                settle(0.15)
                guard let early = paper.presentation() else {
                    throw ReaderTestFailure(description: "\(mode) settled turn \(turn) lost its early presentation")
                }
                let layers = reader.layer?.sublayers ?? []
                let overlayIndex = layers.firstIndex(where: { $0 === overlay }) ?? -1
                try check(layers.enumerated().allSatisfy { index, sibling in
                    sibling === overlay || overlay.zPosition > sibling.zPosition ||
                    (overlay.zPosition == sibling.zPosition && overlayIndex > index)
                }, "\(mode) settled turn \(turn): native PDF content must not cover the animation")
                let earlyAngle = atan2(early.transform.m12, early.transform.m11)
                try check(rotationOverlay(reader) === overlay && earlyAngle < -0.005 && earlyAngle > -.pi / 2,
                          "\(mode) settled turn \(turn) must still be visibly rotating after 150 ms")
                settle(0.20)
                guard let middle = paper.presentation() else {
                    throw ReaderTestFailure(description: "\(mode) settled turn \(turn) lost its mid-turn presentation")
                }
                let middleAngle = atan2(middle.transform.m12, middle.transform.m11)
                try check(rotationOverlay(reader) === overlay && middleAngle < earlyAngle && middleAngle > -.pi / 2,
                          "\(mode) settled turn \(turn) must continue clockwise with the same full-duration effect")
                try captureRotationFrame(overlay, name: "settled-\(mode.replacingOccurrences(of: " ", with: "-"))-\(turn)")
                settle(0.42)
                try check(rotationOverlay(reader) == nil && document.page(at: 0)?.rotation == (turn % 4) * 90,
                          "\(mode) settled turn \(turn) must finish and return to native rendering")
            }
        }
        print("PASS: 24 separately completed turns preserve animation, perspective and shadow in Fit, manual zoom and Rotate All")
    }

    @MainActor private static func checkRotationPresentation(reader: ReaderPDFView, window: NSWindow) throws {
        reader.prefersReducedMotion = { false }
        let document = try makePDF()
        reader.show(document: document, resetZoom: true)
        window.orderFrontRegardless()
        settle(0.12)
        reader.rotate(pageIndices: [0])
        try check(document.page(at: 0)!.rotation == 90, "Document orientation must change before the animation completes")
        guard let overlay = rotationOverlay(reader), let paper = rotationPaper(overlay, index: 0) else {
            throw ReaderTestFailure(description: "A visible rotation must have an opaque page presentation")
        }
        try check(!reader.isFlipped && reader.layer?.isGeometryFlipped == false,
                  "Clockwise direction check assumes PDFKit's native y-up coordinate system")
        try check(overlay.opacity == 1 && overlay.backgroundColor?.alpha == 1 && paper.opacity == 1,
                  "The overlay must hide the already-rotated document without fading the page")
        try check(paper.animation(forKey: "opacity") == nil, "Rotation must not fade the page out")
        let firstTurn = paper.animation(forKey: "clockwiseTurn") as? CABasicAnimation
        try check(firstTurn?.duration == 0.6, "Each rotation must last 600 ms")
        try check(abs((firstTurn?.toValue as? CGFloat ?? 0) + .pi / 2) < 0.0001,
                  "A negative quarter-turn is physically clockwise in the native y-up layer")
        let firstFrameDeadline = Date().addingTimeInterval(0.25)
        repeat {
            settle(0.01)
            if let pose = paper.presentation(), atan2(pose.transform.m12, pose.transform.m11) < -0.005 { break }
        } while Date() < firstFrameDeadline
        guard let early = paper.presentation() else {
            throw ReaderTestFailure(description: "Visible window must produce an animated presentation layer")
        }
        let earlyAngle = atan2(early.transform.m12, early.transform.m11)
        try captureRotationFrame(overlay, name: "rotation-early")
        settle(0.19)
        guard let middle = paper.presentation() else {
            throw ReaderTestFailure(description: "The page must remain present midway through the turn")
        }
        let middleAngle = atan2(middle.transform.m12, middle.transform.m11)
        try captureRotationFrame(overlay, name: "rotation-middle")
        try check(earlyAngle < -0.005 && earlyAngle > -.pi / 2 && middleAngle < earlyAngle && middleAngle > -.pi / 2,
                  "Sampled presentation angles must advance visibly clockwise throughout the turn")
        try check(rotationOverlay(reader) === overlay && middle.opacity == 1,
                  "Delayed internal layout notifications must not cancel or fade the turn")
        for _ in 0..<4 { reader.rotate(pageIndices: [0]) }
        try check(document.page(at: 0)!.rotation == 90 && reader.currentPageIndex == 0,
                  "Five rapid turns must synchronously update the PDF while preserving the active page")
        try check(rotationOverlay(reader) === overlay, "Rapid clicks must reuse the presentation rather than replace it")
        for quarter in 1...4 {
            let deadline = Date().addingTimeInterval(1)
            var animation: CABasicAnimation?
            repeat {
                settle(0.01)
                animation = paper.animation(forKey: "clockwiseTurn") as? CABasicAnimation
                if abs((animation?.fromValue as? CGFloat ?? 1) + CGFloat(quarter) * .pi / 2) < 0.0001 { break }
            } while Date() < deadline
            let start = animation?.fromValue as? CGFloat ?? 1
            let end = animation?.toValue as? CGFloat ?? 1
            try check(abs(start + CGFloat(quarter) * .pi / 2) < 0.0001 && abs(end - start + .pi / 2) < 0.0001,
                      "Queued turn \(quarter + 1) must advance another clockwise 90 degrees, including across 360")
            try check(paper.opacity == 1, "Every queued turn must keep the page fully visible")
        }
        settle(0.66)
        try check(rotationOverlay(reader) == nil, "The temporary raster presentation must be removed after the final turn")
        print("PASS: live 600 ms clockwise presentation samples \(earlyAngle), \(middleAngle); five rapid turns cross 360 without resets")

        let manyPages = try makePDF(pageCount: 12, pageSize: CGSize(width: 600, height: 300))
        reader.show(document: manyPages, resetZoom: true)
        settle()
        reader.setManualZoom(percent: 20)
        settle(0.08)
        let visibleIndices = visiblePageIndices(reader)
        try check(visibleIndices.count > 3, "The all-page fixture must show more than three pages")
        reader.rotate(pageIndices: Array(0..<12))
        guard let allOverlay = rotationOverlay(reader) else {
            throw ReaderTestFailure(description: "Rotate All must produce its visible presentation")
        }
        let visibleAfter = visiblePageIndices(reader)
        for index in visibleIndices.union(visibleAfter) {
            try check(rotationPaper(allOverlay, index: index) != nil, "All visible pages, including newly exposed ones, must be represented")
        }
        let pixelCount = (allOverlay.sublayers ?? []).reduce(0) { count, position in
            guard let contents = position.sublayers?.first?.sublayers?.first?.contents else { return count }
            let image = contents as! CGImage
            return count + image.width * image.height
        }
        try check(pixelCount <= 4_000_000, "Temporary page rasters must share a bounded pixel budget")
        try check(abs(reader.scaleFactor - 0.2) < 0.001, "Animated Rotate All must preserve manual zoom")
        reader.setFit()
        try check(rotationOverlay(reader) == nil, "Changing zoom must immediately restore native PDFKit rendering")
        reader.rotate(pageIndices: [reader.currentPageIndex])
        reader.scrollByArrow(direction: 1)
        try check(rotationOverlay(reader) == nil, "User scrolling must remove the frozen presentation")
        reader.setFit()
        reader.rotate(pageIndices: [reader.currentPageIndex])
        window.setContentSize(NSSize(width: 820, height: 660))
        reader.layoutSubtreeIfNeeded()
        try check(rotationOverlay(reader) == nil, "Resizing must remove stale page geometry")
        reader.rotate(pageIndices: [reader.currentPageIndex])
        reader.document = nil
        try check(rotationOverlay(reader) == nil, "Closing a document must remove its temporary page content")
        reader.show(document: try makePDF(), resetZoom: true)
        settle()
        reader.prefersReducedMotion = { true }
        reader.rotate(pageIndices: [0])
        try check(reader.document?.page(at: 0)?.rotation == 90 && rotationOverlay(reader) == nil,
                  "Reduce Motion must retain correct synchronous rotation without the visual spin")
        let mixed = try makePDF(pageCount: 2, pageSize: CGSize(width: 612, height: 792))
        mixed.page(at: 1)!.rotation = 0
        var finalReportedPage = 0
        var finalReportedCount = 0
        let priorPageCallback = reader.onPageChanged
        reader.onPageChanged = { page, count in
            finalReportedPage = page
            finalReportedCount = count
            priorPageCallback?(page, count)
        }
        reader.prefersReducedMotion = { false }
        reader.show(document: mixed, resetZoom: true)
        settle()
        reader.setManualZoom(percent: 65)
        for _ in 0..<5 { reader.rotate(pageIndices: [reader.currentPageIndex]) }
        reader.rotate(pageIndices: [0, 1])
        reader.setFit() // Cancel the first queue while keeping its active page in view.
        for _ in 0..<2 { reader.rotate(pageIndices: [reader.currentPageIndex]) }
        let completionDeadline = Date().addingTimeInterval(3)
        while rotationOverlay(reader) != nil && Date() < completionDeadline { settle(0.02) }
        settle(0.06)
        let firstPage = mixed.page(at: 0)!
        let currentRect = reader.convert(firstPage.bounds(for: .cropBox), from: firstPage)
        let visibleRect = currentRect.intersection(reader.bounds)
        try check(rotationOverlay(reader) == nil && firstPage.rotation == 0,
                  "The two queued turns after Fit must complete on the same page")
        try check(reader.currentPage === firstPage && reader.currentPageIndex == 0,
                  "After rapid mixed rotations, the actual PDFKit current page must remain page 1")
        try check(visibleRect.width * visibleRect.height > reader.bounds.width * reader.bounds.height * 0.75,
                  "The active page must fill a meaningful part of the viewport, not become a thin strip")
        try check(abs(currentRect.midX - reader.bounds.midX) < 1,
                  "Fit must keep the active page horizontally centered after mixed rotations")
        try check(finalReportedPage == 1 && finalReportedCount == 2,
                  "The page callback must reflect the actual visible page after the rotation overlay ends")
        reader.onPageChanged = priorPageCallback
        reader.prefersReducedMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        window.setContentSize(NSSize(width: 800, height: 650))
        window.orderOut(nil)
        print("PASS: all visible pages, bounded snapshots, Fit centering, manual zoom, scroll/resize/close cleanup and Reduce Motion")
    }

    private static func visiblePageIndices(_ reader: ReaderPDFView) -> Set<Int> {
        guard let document = reader.document else { return [] }
        return Set(reader.visiblePages.filter {
            reader.convert($0.bounds(for: reader.displayBox), from: $0).intersects(reader.bounds)
        }.map { document.index(for: $0) })
    }

    private static func rotationOverlay(_ reader: ReaderPDFView) -> CALayer? {
        reader.layer?.sublayers?.first { $0.name == "reader.rotation.overlay" }
    }

    private static func rotationPaper(_ overlay: CALayer, index: Int) -> CALayer? {
        overlay.sublayers?.first { $0.name == "reader.rotation.page.\(index)" }?.sublayers?.first?.sublayers?.first
    }

    private static func captureRotationFrame(_ overlay: CALayer, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["READER_ROTATION_CAPTURE_DIR"],
              let presentation = overlay.presentation() else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = Int(overlay.bounds.width), height = Int(overlay.bounds.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        presentation.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try data.write(to: directory.appendingPathComponent(name).appendingPathExtension("png"))
    }

    @MainActor private static func settle(_ seconds: TimeInterval = 0.04) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor private static func makePDF(pageCount: Int = 3, pageSize: CGSize = CGSize(width: 600, height: 800)) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ReaderTestFailure(description: "Could not create PDF data consumer")
        }
        var bounds = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw ReaderTestFailure(description: "Could not create PDF context")
        }
        for index in 1...pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.textPosition = CGPoint(x: 60, y: 680)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello reader, page \(index)",
                attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 24, nil)]))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw ReaderTestFailure(description: "Generated PDF must open")
        }
        document.page(at: 1)!.rotation = 90
        document.page(at: 2)?.rotation = 270
        let field = PDFAnnotation(bounds: CGRect(x: 60, y: 450, width: 260, height: 30), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "unchanged-text"
        field.widgetStringValue = "Original form value"
        field.isReadOnly = false
        document.page(at: 0)!.addAnnotation(field)
        let checkbox = PDFAnnotation(bounds: CGRect(x: 60, y: 400, width: 20, height: 20), forType: .widget, withProperties: nil)
        checkbox.widgetFieldType = .button
        checkbox.widgetControlType = .checkBoxControl
        checkbox.fieldName = "unchanged-checkbox"
        checkbox.buttonWidgetState = .offState
        document.page(at: 0)!.addAnnotation(checkbox)
        return document
    }

    @MainActor private static func mouseEvent(reader: ReaderPDFView, page: PDFPage, point: CGPoint,
                                             clicks: Int = 1, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try mouseEvent(reader: reader, viewPoint: reader.convert(point, from: page), clicks: clicks, type: type)
    }

    @MainActor private static func mouseEvent(reader: ReaderPDFView, viewPoint: CGPoint,
                                             clicks: Int = 1, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        let location = reader.convert(viewPoint, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                            timestamp: 0, windowNumber: reader.window?.windowNumber ?? 0,
                                            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else {
            throw ReaderTestFailure(description: "Could not create mouse event")
        }
        return event
    }

    private static func keyEvent(key: UInt16, text: String = "", modifiers: NSEvent.ModifierFlags = [],
                                 repeatKey: Bool = false) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: 0, context: nil, characters: text,
                                          charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: key) else {
            throw ReaderTestFailure(description: "Could not create key event")
        }
        return event
    }
}
