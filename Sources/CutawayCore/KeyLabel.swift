import Foundation
import AppKit
import Carbon.HIToolbox

/// Turns a key event into the label a viewer should read.
public enum KeyLabel {

    public struct Result {
        public let text: String
        /// Plain typing, which the overlay merges into words rather than
        /// flashing a box per letter.
        public let isText: Bool
    }

    static let named: [Int: String] = [
        kVK_Return: "return", kVK_Tab: "tab", kVK_Space: "space",
        kVK_Delete: "delete", kVK_ForwardDelete: "fn delete",
        kVK_Escape: "esc", kVK_Home: "home", kVK_End: "end",
        kVK_PageUp: "page up", kVK_PageDown: "page down",
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_KeypadEnter: "enter",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    public static func make(from event: NSEvent) -> Result? {
        // A bare modifier press is noise on its own; it only matters as part of
        // a chord, which arrives with the keyDown.
        guard event.type == .keyDown else { return nil }

        let flags = event.modifierFlags
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option)  { prefix += "⌥" }
        if flags.contains(.shift)   { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }

        let code = Int(event.keyCode)
        if let name = named[code] {
            return Result(text: prefix + name, isText: false)
        }

        // charactersIgnoringModifiers so ⌘⇧S reads as that rather than ⌘S.
        guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return nil }
        let ch = raw.uppercased()
        guard let scalar = ch.unicodeScalars.first,
              scalar.value >= 32, scalar.value != 127 else { return nil }

        if prefix.isEmpty {
            // Plain typing. Shown as the character actually produced, so
            // shifted punctuation and capitals read correctly.
            return Result(text: event.characters ?? ch, isText: true)
        }
        return Result(text: prefix + ch, isText: false)
    }
}
