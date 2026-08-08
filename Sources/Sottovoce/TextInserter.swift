import AppKit
import CoreGraphics

/// Inserts text into the frontmost app, either by pasting (with clipboard
/// restore) or by synthesizing unicode keyboard events.
enum TextInserter {
    private static var savedClipboard: String?
    private static var restoreWork: DispatchWorkItem?

    /// Markers from <https://nspasteboard.org>: clipboard managers that honour
    /// them leave the entry out of their history. Set while `paste` borrows the
    /// clipboard, so a dictation only passing through isn't retained by a third
    /// party — dictated text can be sensitive, which is also why the Recent
    /// Dictations list is memory-only.
    private static let transientMarkers: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.ConcealedType"),
    ]

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        switch Prefs.insertionMethod {
        case .paste:
            paste(text)
        case .type:
            type(text)
            // Typing never touches the clipboard, so the preference has to put
            // the text there itself for the two methods to mean the same thing.
            if Prefs.keepInClipboard { copy(text) }
        }
    }

    // MARK: - Paste

    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let keep = Prefs.keepInClipboard

        // If a restore is still pending we already hold the user's original
        // clipboard; don't overwrite it with our own previous segment.
        if !keep, restoreWork == nil {
            savedClipboard = pasteboard.string(forType: .string)
        }
        restoreWork?.cancel()
        restoreWork = nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if !keep {
            for marker in transientMarkers {
                pasteboard.setString("", forType: marker)
            }
        }
        postKeystroke(keyCode: 9, flags: .maskCommand) // ⌘V

        // Keeping it means there is nothing to restore: whatever was on the
        // clipboard before is deliberately gone.
        guard !keep else {
            savedClipboard = nil
            return
        }

        let work = DispatchWorkItem {
            restoreWork = nil
            pasteboard.clearContents()
            if let saved = savedClipboard {
                pasteboard.setString(saved, forType: .string)
            }
            savedClipboard = nil
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Deliberate copy: no transient markers, the point is for it to be kept.
    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown
            ) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyManager.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Typing

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        // keyboardSetUnicodeString caps out around 20 UTF-16 units per event.
        let chunkSize = 20
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])
            index = end

            for keyDown in [true, false] {
                guard let event = CGEvent(
                    keyboardEventSource: source, virtualKey: 0, keyDown: keyDown
                ) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.setIntegerValueField(.eventSourceUserData, value: HotkeyManager.syntheticEventMarker)
                event.post(tap: .cghidEventTap)
            }
            usleep(3000)
        }
    }
}
