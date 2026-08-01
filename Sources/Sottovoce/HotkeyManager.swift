import AppKit
import CoreGraphics

/// Listens for the dictation hotkey via a CGEvent tap (requires Accessibility trust).
/// The tap runs on the main run loop, so all callbacks fire on the main thread.
final class HotkeyManager {
    /// Marker put on events we synthesize (paste/typing) so the tap ignores them.
    static let syntheticEventMarker: Int64 = 0x54524E53 // "TRNS"

    var keyCode: CGKeyCode = 61
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Esc pressed; return true to consume the event (i.e. a dictation was cancelled).
    var onEscape: (() -> Bool)?
    var onTapStarted: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var captureHandler: ((CGKeyCode?) -> Void)?
    private var swallowedKeyDown = false

    var isRunning: Bool { tap != nil }

    /// Creates the event tap; retries every 3 s until Accessibility is granted.
    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.start()
            }
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onTapStarted?()
    }

    /// Captures the next key press (regular key or modifier) as the new hotkey.
    /// Calls the handler with nil if capture is cancelled with Esc.
    func beginCapture(_ handler: @escaping (CGKeyCode?) -> Void) {
        captureHandler = handler
    }

    func cancelCapture() {
        captureHandler?(nil)
        captureHandler = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return pass
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if let handler = captureHandler {
            switch type {
            case .keyDown:
                captureHandler = nil
                handler(code == 53 ? nil : code)
                return nil
            case .keyUp:
                return nil
            case .flagsChanged:
                // Capture a modifier on press (flag transitions to set). Caps Lock is
                // excluded: it toggles instead of reporting press/release.
                if code != 57, let mask = KeyNames.modifierMasks[code], event.flags.contains(mask) {
                    captureHandler = nil
                    handler(code)
                }
                return pass
            default:
                return pass
            }
        }

        switch type {
        case .flagsChanged:
            guard code == keyCode, let mask = KeyNames.modifierMasks[code] else { return pass }
            if event.flags.contains(mask) {
                onDown?()
            } else {
                onUp?()
            }
            return pass

        case .keyDown:
            if code == 53, let onEscape, onEscape() {
                return nil
            }
            guard code == keyCode else { return pass }
            // A chord like ⌘+<hotkey> is regular typing, not the hotkey.
            let chordFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            guard event.flags.intersection(chordFlags).isEmpty else { return pass }
            swallowedKeyDown = true
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onDown?()
            }
            return nil

        case .keyUp:
            guard code == keyCode, swallowedKeyDown else { return pass }
            swallowedKeyDown = false
            onUp?()
            return nil

        default:
            return pass
        }
    }
}
