import Foundation
import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts.
///
/// The point of the whole tool is a clean take, and you cannot get one if
/// starting and stopping means clicking a window that is then in the footage.
/// Carbon's RegisterEventHotKey is used rather than an NSEvent monitor because
/// it needs no Input Monitoring permission and fires even when Cutaway is not
/// the active app, which is exactly when you need it.
public final class Hotkey {

    /// What a shortcut is for. Each one can be rebound, and is stored by
    /// this name, so a new build never loses what someone chose.
    public enum Action: String, CaseIterable {
        case record, pause, captureArea, captureScreen, captureRepeat, captureScrolling

        public var title: String {
            switch self {
            case .record: return "Start or stop recording"
            case .pause: return "Pause a recording"
            case .captureArea: return "Capture an area"
            case .captureScreen: return "Capture the screen"
            case .captureRepeat: return "Capture the same area again"
            case .captureScrolling: return "Scrolling capture"
            }
        }

        public var fallback: Combo {
            switch self {
            case .record: return .record
            case .pause: return .pause
            case .captureArea: return .captureArea
            case .captureScreen: return .captureScreen
            case .captureRepeat: return .captureRepeat
            case .captureScrolling: return .captureScrolling
            }
        }

        /// The one in use: whatever was chosen, else the default.
        public var combo: Combo {
            guard let saved = UserDefaults.standard.dictionary(forKey: "hotkey.\(rawValue)"),
                  let key = saved["key"] as? Int, let mods = saved["mods"] as? Int else {
                return fallback
            }
            return Combo(keyCode: UInt32(key), modifiers: UInt32(mods),
                         label: Combo.describe(key: UInt32(key), modifiers: UInt32(mods)))
        }

        public func set(_ combo: Combo?) {
            guard let combo else {
                UserDefaults.standard.removeObject(forKey: "hotkey.\(rawValue)")
                return
            }
            UserDefaults.standard.set(["key": Int(combo.keyCode), "mods": Int(combo.modifiers)],
                                      forKey: "hotkey.\(rawValue)")
        }
    }

    public struct Combo {
        public let keyCode: UInt32
        public let modifiers: UInt32
        public let label: String

        public init(keyCode: UInt32, modifiers: UInt32, label: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.label = label
        }

        /// Builds one from a key press, for the recorder in Settings.
        public init?(event: NSEvent) {
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            // a bare letter would fire while typing, so insist on a modifier
            guard mods != 0 else { return nil }
            keyCode = UInt32(event.keyCode)
            modifiers = mods
            label = Combo.describe(key: UInt32(event.keyCode), modifiers: mods)
        }

        /// How the shortcut reads in a menu: ⌘⇧6, ⌃⌥A.
        public static func describe(key: UInt32, modifiers: UInt32) -> String {
            var out = ""
            if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
            return out + (keyNames[Int(key)] ?? "?")
        }

        static let keyNames: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc",
            kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        ]

        /// ⌘⇧8 to start and stop, ⌘⇧9 to pause. Chosen to stay clear of the
        /// system screenshot shortcuts on ⌘⇧3/4/5.
        public static let record = Combo(keyCode: UInt32(kVK_ANSI_8),
                                         modifiers: UInt32(cmdKey | shiftKey),
                                         label: "⌘⇧8")
        public static let pause = Combo(keyCode: UInt32(kVK_ANSI_9),
                                        modifiers: UInt32(cmdKey | shiftKey),
                                        label: "⌘⇧9")
        /// ⌘⇧6 grabs an area, ⌘⇧7 the whole screen. Again clear of ⌘⇧3/4/5.
        public static let captureArea = Combo(keyCode: UInt32(kVK_ANSI_6),
                                              modifiers: UInt32(cmdKey | shiftKey),
                                              label: "⌘⇧6")
        public static let captureScreen = Combo(keyCode: UInt32(kVK_ANSI_7),
                                                modifiers: UInt32(cmdKey | shiftKey),
                                                label: "⌘⇧7")
        public static let captureScrolling = Combo(keyCode: UInt32(kVK_ANSI_5),
                                                   modifiers: UInt32(cmdKey | shiftKey),
                                                   label: "⌘⇧5")
        /// Same area again, for a run of shots of the same thing.
        public static let captureRepeat = Combo(keyCode: UInt32(kVK_ANSI_R),
                                                modifiers: UInt32(cmdKey | shiftKey),
                                                label: "⌘⇧R")
    }

    /// Registers whatever each action is currently bound to, replacing
    /// anything registered before.
    public func rebind(_ handlers: [Action: () -> Void]) {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs = []
        self.handlers = [:]
        nextID = 1
        for (action, run) in handlers {
            if !register(action.combo, action: run) {
                Log.line("shortcut \(action.combo.label) for \(action.title) is taken by another app")
            }
        }
    }

    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    nonisolated(unsafe) private static var shared: Hotkey?

    public init() {
        Hotkey.shared = self
        installHandler()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async {
                Hotkey.shared?.handlers[hkID.id]?()
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    @discardableResult
    public func register(_ combo: Combo, action: @escaping () -> Void) -> Bool {
        let id = EventHotKeyID(signature: OSType(0x43555457), id: nextID)  // 'CUTW'
        handlers[nextID] = action
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Log.line("hotkey \(combo.label) unavailable (already taken by another app)")
            return false
        }
        refs.append(ref)
        return true
    }

    deinit {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Full-screen countdown before capture starts, so you can get to the right
/// window first. Borderless, click-through, and on every space.
public final class Countdown {

    private var window: NSWindow?
    private var label: NSTextField?

    public init() {}

    /// Counts down, then calls `then` on the main queue.
    public func run(from seconds: Int = 3, then: @escaping () -> Void) {
        guard seconds > 0 else { then(); return }
        guard let screen = NSScreen.main else { then(); return }

        let w = NSWindow(contentRect: screen.frame,
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        // Click-through: the countdown must never steal a click from whatever
        // you are about to demo.
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let text = NSTextField(labelWithString: "\(seconds)")
        text.font = NSFont.monospacedDigitSystemFont(ofSize: 220, weight: .bold)
        text.textColor = .white
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false

        let backing = NSView(frame: screen.frame)
        backing.wantsLayer = true
        backing.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        backing.addSubview(text)
        NSLayoutConstraint.activate([
            text.centerXAnchor.constraint(equalTo: backing.centerXAnchor),
            text.centerYAnchor.constraint(equalTo: backing.centerYAnchor),
        ])
        w.contentView = backing
        w.orderFrontRegardless()

        window = w
        label = text

        var remaining = seconds
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.dismiss()
                // A beat after the overlay goes, so it is never in frame one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { then() }
            } else {
                self?.label?.stringValue = "\(remaining)"
            }
        }
    }

    public func dismiss() {
        window?.orderOut(nil)
        window = nil
        label = nil
    }
}
