import AppKit

/// The same linear, five-percentage-point control used by Photo Viewer.
final class ZoomControl: NSView {
    var onFit: (() -> Void)?
    var onManual: ((Double) -> Void)?
    var isEnabled = false { didSet { refreshControls() } }

    private let fitButton = NSButton(title: "Fit", target: nil, action: nil)
    private let minusButton = NSButton(title: "−", target: nil, action: nil)
    private let plusButton = NSButton(title: "+", target: nil, action: nil)
    private let slider = NSSlider(value: 100, minValue: 20, maxValue: 200, target: nil, action: nil)
    private let percentageLabel = NSTextField(labelWithString: "—")
    private let minimumLabel = NSTextField(labelWithString: "Min. 20%")
    private let maximumLabel = NSTextField(labelWithString: "Max. 200%")
    private var percentage = 100.0
    private var fit = true

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 48) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [fitButton, minusButton, plusButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = Self.font()
            button.alignment = .center
            button.target = self
            addSubview(button)
        }
        fitButton.action = #selector(chooseFit)
        minusButton.action = #selector(zoomOut)
        plusButton.action = #selector(zoomIn)
        fitButton.setAccessibilityLabel("Fit to width")
        minusButton.setAccessibilityLabel("Zoom out")
        plusButton.setAccessibilityLabel("Zoom in")
        fitButton.toolTip = "Fit the current page to the window width (⌘9)"
        minusButton.toolTip = "Zoom out by 5% (minimum 20%, ⌘−)"
        plusButton.toolTip = "Zoom in by 5% (maximum 200%, ⌘+)"

        // Native ticks still draw with some macOS appearances even when their cell
        // drawing hook is overridden. Snap in the action instead, with no ticks.
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.controlSize = .small
        slider.font = Self.font()
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel("Zoom level")
        addSubview(slider)

        for label in [percentageLabel, minimumLabel, maximumLabel] {
            label.font = Self.font()
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.isSelectable = false
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        refreshControls()
    }

    required init?(coder: NSCoder) { nil }

    func update(percent: Double, isFit: Bool) {
        percentage = percent.isFinite ? percent : 100
        fit = isFit
        refreshControls()
    }

    override func layout() {
        super.layout()
        // Captions share a baseline; the current percentage follows the native thumb.
        fitButton.frame = NSRect(x: 0, y: 2, width: 48, height: 24)
        minusButton.frame = NSRect(x: 57, y: 2, width: 30, height: 24)
        slider.frame = NSRect(x: 113, y: 4, width: 94, height: 20)
        plusButton.frame = NSRect(x: 249, y: 2, width: 30, height: 24)
        minimumLabel.frame = NSRect(x: 41, y: 28, width: 62, height: 20)
        maximumLabel.frame = NSRect(x: 229, y: 28, width: 70, height: 20)
        // Cell knobRect can describe its previous draw immediately after a menu or
        // keyboard zoom change. Derive the label from the value, as Photo Viewer does.
        let fraction = CGFloat((Self.normalized(percentage) - 20) / 180)
        // Only its width is reused: the cached knob position may still describe
        // the preceding zoom value, while the width reflects native .small sizing.
        let measuredThumbWidth = (slider.cell as? NSSliderCell)?.knobRect(flipped: slider.isFlipped).width ?? 0
        let thumbDiameter: CGFloat = measuredThumbWidth > 0 ? measuredThumbWidth : 18
        let x = slider.frame.minX + thumbDiameter / 2 + fraction * (slider.frame.width - thumbDiameter)
        percentageLabel.frame = NSRect(x: x - 31, y: 28, width: 62, height: 20)
    }

    private static func font() -> NSFont {
        NSFont(name: "Avenir-Book", size: 13) ?? NSFont(name: "Avenir", size: 13)
            ?? NSFont.systemFont(ofSize: 13)
    }

    private func refreshControls() {
        let manual = Self.normalized(percentage)
        slider.doubleValue = manual
        slider.isEnabled = isEnabled
        minusButton.isEnabled = isEnabled && manual > 20
        plusButton.isEnabled = isEnabled && manual < 200
        fitButton.isEnabled = isEnabled
        // A fixed, unpadded title stays centered in both active and manual modes.
        fitButton.title = "Fit"
        fitButton.bezelColor = fit ? NSColor.controlAccentColor : nil
        fitButton.contentTintColor = fit ? .white : .labelColor
        fitButton.setAccessibilityValue(fit ? "On" : "Off")
        percentageLabel.stringValue = isEnabled ? "\(Int(percentage.rounded()))%" : "—"
        // Preserve NSSlider's numeric AX value so assistive tools can adjust it.
        slider.setAccessibilityHelp(isEnabled ? "\(fit ? "Fit, " : "")\(Int(percentage.rounded())) percent" : "No PDF")
        needsLayout = true
    }

    private static func normalized(_ value: Double) -> Double {
        min(200, max(20, (value / 5).rounded(.toNearestOrAwayFromZero) * 5))
    }

    @objc private func chooseFit() { if isEnabled { onFit?() } }
    func decrease() { if isEnabled { onManual?(max(20, Self.normalized(percentage) - 5)) } }
    @objc private func zoomOut() { decrease() }
    func increase() { if isEnabled { onManual?(min(200, Self.normalized(percentage) + 5)) } }
    @objc private func zoomIn() { increase() }
    @objc private func sliderChanged() {
        guard isEnabled else { return }
        let value = Self.normalized(slider.doubleValue)
        update(percent: value, isFit: false)
        onManual?(value)
    }
}
