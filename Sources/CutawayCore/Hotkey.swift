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

    public struct Combo {
        public let keyCode: UInt32
        public let modifiers: UInt32
        public let label: String

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
