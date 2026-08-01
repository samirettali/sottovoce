import AppKit

/// Pauses scriptable media players when dictation starts and resumes only the
/// ones it paused when dictation ends.
///
/// Uses AppleScript via `osascript` (the private MediaRemote framework that
/// covers system-wide "Now Playing" is restricted since macOS 15.4). Scripts
/// run on a background serial queue so a pending Automation consent dialog
/// can't block the main thread mid-dictation.
final class MediaPauser {
    private struct Player {
        let bundleID: String
        /// Pauses the player if it is playing; prints "paused" if it did.
        let pauseIfPlayingScript: String
        let resumeScript: String
    }

    private static let players: [Player] = [
        Player(
            bundleID: "com.spotify.client",
            pauseIfPlayingScript: """
            tell application id "com.spotify.client"
                if player state is playing then
                    pause
                    return "paused"
                end if
            end tell
            """,
            resumeScript: #"tell application id "com.spotify.client" to play"#
        ),
        Player(
            bundleID: "com.apple.Music",
            pauseIfPlayingScript: """
            tell application id "com.apple.Music"
                if player state is playing then
                    pause
                    return "paused"
                end if
            end tell
            """,
            resumeScript: #"tell application id "com.apple.Music" to play"#
        ),
        Player(
            bundleID: "org.videolan.vlc",
            pauseIfPlayingScript: """
            tell application id "org.videolan.vlc"
                if playing then
                    play
                    return "paused"
                end if
            end tell
            """,
            // VLC's `play` toggles, so only resume when actually paused.
            resumeScript: """
            tell application id "org.videolan.vlc"
                if not playing then play
            end tell
            """
        ),
    ]

    private let queue = DispatchQueue(label: "dev.samir.sottovoce.media")
    private var pausedBundleIDs: [String] = []

    func pauseActivePlayers() {
        queue.async {
            guard self.pausedBundleIDs.isEmpty else { return }
            // Only script apps that are already running — sending an Apple
            // event to a closed app would launch it.
            for player in Self.players where Self.isRunning(player.bundleID) {
                if Self.runScript(player.pauseIfPlayingScript) == "paused" {
                    self.pausedBundleIDs.append(player.bundleID)
                }
            }
        }
    }

    func resumePausedPlayers() {
        queue.async {
            for bundleID in self.pausedBundleIDs {
                guard let player = Self.players.first(where: { $0.bundleID == bundleID }),
                      Self.isRunning(bundleID)
                else { continue }
                Self.runScript(player.resumeScript)
            }
            self.pausedBundleIDs.removeAll()
        }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @discardableResult
    private static func runScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
