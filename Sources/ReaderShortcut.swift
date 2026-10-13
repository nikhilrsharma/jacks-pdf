import AppKit

enum ReaderShortcut: Equatable {
    case closeWindow, zoomIn, zoomOut, actualSize, fit, rotateCurrent, rotateAll
    static func command(for event: NSEvent) -> ReaderShortcut? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command, .option], key == "r" { return .rotateAll }
        if flags == .command || flags == [.command, .shift], key == "+" || key == "=" { return .zoomIn }
        guard flags == .command else { return nil }
        switch key {
        case "w": return .closeWindow
        case "-": return .zoomOut
        case "0": return .actualSize
        case "9": return .fit
        case "r": return .rotateCurrent
        default: return nil
        }
    }
}
