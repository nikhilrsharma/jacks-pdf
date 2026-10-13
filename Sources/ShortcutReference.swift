enum ShortcutReference {
    static let rows: [(String, String)] = [
        ("Open PDF", "⌘O"),
        ("Save As", "⇧⌘S"),
        ("Close window / Quit", "⌘W / ⌘Q"),
        ("Enter / exit full screen", "⌃⌘F"),
        ("Scroll up / down", "↑ / ↓"),
        ("Previous / next PDF", "← / →"),
        ("Scroll a screen up", "Page Up or fn↑"),
        ("Scroll a screen down", "Page Down or fn↓"),
        ("Zoom in / out", "⌘+ (or ⌘=) / ⌘−"),
        ("Actual size (100%) / Fit width", "⌘0 / ⌘9"),
        ("Rotate current page clockwise", "⌘R"),
        ("Rotate all pages clockwise", "⌥⌘R"),
        ("Copy / Select all text", "⌘C / ⌘A"),
        ("Clear selection / dismiss dialog", "Esc"),
        ("Use highlighted dialog button", "Return")
    ]
    static let notes = "⌘ Command   ⌥ Option   ⌃ Control   ⇧ Shift\nFolder navigation requires access to the folder.\nText selection and copying depend on PDF permissions."
}
