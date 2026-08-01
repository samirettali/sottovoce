import AppKit
import SwiftUI

// MARK: - Panel

/// Borderless, non-activating, click-through panel that floats above
/// everything (including fullscreen apps) on every Space.
private final class OverlayPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    private let panelSize = CGSize(width: 600, height: 150)
    private let panel: OverlayPanel

    init() {
        panel = OverlayPanel(size: panelSize)
        let host = NSHostingView(rootView: OverlayView())
        host.frame = CGRect(origin: .zero, size: panelSize)
        panel.contentView = host
        reposition()
        panel.orderFrontRegardless()
    }

    /// Places the panel on the screen the user is working on (the one with the
    /// pointer), at the configured position.
    func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let origin = Prefs.overlayPosition.origin(
            panelSize: panelSize, in: screen.visibleFrame
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Surface

/// Parakeet-style dark glass shared by every overlay element, so transitions
/// read as one surface changing shape.
private extension View {
    func overlaySurface<S: InsettableShape>(in shape: S, shadowY: CGFloat) -> some View {
        self
            .background(shape.fill(Color.black.opacity(0.82)))
            .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 14, y: shadowY)
    }
}

// MARK: - View

struct OverlayView: View {
    @ObservedObject private var app = AppState.shared
    @AppStorage(PrefKey.overlayPosition) private var positionRaw = OverlayPosition.bottomCenter.rawValue
    @AppStorage(PrefKey.showIdleOverlay) private var showIdleOverlay = false

    private var position: OverlayPosition {
        OverlayPosition(rawValue: positionRaw) ?? .bottomCenter
    }

    private enum Mode: Equatable {
        case hidden, ready, hold, locked, finishing, done, preview
        case error(String)
    }

    private var mode: Mode {
        if let message = app.errorMessage { return .error(message) }
        switch app.phase {
        case .holdRecording, .pendingLock: return .hold
        case .lockedRecording, .pendingUnlock: return .locked
        case .finishing: return .finishing
        case .idle:
            if app.flashDone { return .done }
            if app.overlayPreview { return .preview }
            if showIdleOverlay { return .ready }
            return .hidden
        }
    }

    private var isRecordingMode: Bool {
        mode == .hold || mode == .locked || mode == .finishing
    }

    /// Live text shown in the bubble next to the pill.
    private var bubbleText: String? {
        switch mode {
        case .hold, .locked, .finishing:
            return app.previewText.isEmpty ? nil : app.previewText
        case .preview:
            return "Overlay appears here"
        default:
            return nil
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch position {
        case .topLeft, .bottomLeft: return .leading
        case .topCenter, .bottomCenter: return .center
        case .topRight, .bottomRight: return .trailing
        }
    }

    var body: some View {
        ZStack {
            if mode != .hidden {
                // The bubble sits toward the screen center: below the pill when
                // the overlay is at the top, above it when at the bottom.
                VStack(alignment: horizontalAlignment, spacing: 8) {
                    if position.isTop {
                        pill
                        bubble
                    } else {
                        bubble
                        pill
                    }
                }
                .transition(
                    .scale(scale: 0.9, anchor: position.isTop ? .top : .bottom)
                        .combined(with: .opacity)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position.alignment)
        .padding(20)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: mode)
        .animation(.easeOut(duration: 0.18), value: bubbleText)
    }

    // MARK: Pieces

    @ViewBuilder
    private var pill: some View {
        switch mode {
        case .ready, .preview:
            idleChip
        case .hold, .locked, .finishing:
            recordingPill
        case .done:
            doneChip
        case .error(let message):
            errorPill(message)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if let text = bubbleText {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
                .truncationMode(.head)
                .multilineTextAlignment(textAlignment)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: 400)
                .overlaySurface(
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                    shadowY: shadowY
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    private var textAlignment: TextAlignment {
        switch horizontalAlignment {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }

    private var shadowY: CGFloat { position.isTop ? 4 : 6 }

    /// Compact idle indicator: a small mic chip that shows the app is running.
    private var idleChip: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 32, height: 32)
            .overlaySurface(in: Circle(), shadowY: shadowY)
    }

    private var doneChip: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.green)
            .frame(width: 32, height: 32)
            .overlaySurface(in: Circle(), shadowY: shadowY)
    }

    /// The compact Parakeet-style capsule: status dot · timer · waveform strip.
    private var recordingPill: some View {
        HStack(spacing: 9) {
            statusIcon
                .frame(width: 12, height: 12)

            Text(timerString)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))

            WaveformStrip(level: app.level, active: mode != .finishing)
        }
        .padding(.horizontal, 13)
        .frame(height: 32)
        .overlaySurface(in: Capsule(), shadowY: shadowY)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch mode {
        case .finishing:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
        case .locked:
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.purple)
        default:
            PulsingDot(live: app.sessionReady)
        }
    }

    private var timerString: String {
        guard let start = app.recordingStartedAt else { return "0:00" }
        let end = app.recordingEndedAt ?? Date()
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func errorPill(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(maxWidth: 400)
        .overlaySurface(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            shadowY: shadowY
        )
    }
}

// MARK: - Recording dot

/// Red recording dot; gray while the session is still connecting.
/// Pulses with the same 1.1 s cadence in both states.
private struct PulsingDot: View {
    var live: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(live ? Color.red : Color.white.opacity(0.4))
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.45 : 1)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
            .animation(.easeOut(duration: 0.3), value: live)
            .onAppear { pulsing = true }
    }
}

// MARK: - Waveform strip

/// Thin scrolling level-history bars, newest on the right.
private struct WaveformStrip: View {
    var level: Float
    var active: Bool

    private static let barCount = 14
    @State private var history = [Float](repeating: 0, count: barCount)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2, height: 3 + CGFloat(history[index]) * 11)
            }
        }
        .frame(height: 14)
        .onChange(of: level) { _, newLevel in
            guard active else { return }
            history.removeFirst()
            history.append(newLevel)
        }
        .animation(.linear(duration: 0.05), value: history)
    }
}
