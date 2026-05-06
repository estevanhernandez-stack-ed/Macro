// EditorTransport.swift
// UI — transport controls in the editor (item 8a).
//
// Play/pause + ⏮ / ⏭ + scrubber + MM:SS / MM:SS time indicator.
//
// In 8a the play button is visual only — there's no decode loop, no
// engine kickoff. 8b/c wires Engine.shared.startPlayback through the
// playing/paused binding. The scrubber is real and read-only-friendly:
// drag the cursor, the playhead binding updates, lanes redraw.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + locked v2 mockup. PRD ref: Epic C scrub stories.

import SwiftUI

struct EditorTransport: View {

    @Binding var playheadSeconds: Double
    @Binding var isPlaying: Bool
    let duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            HStack(spacing: MacRoTheme.Spacing.md) {
                TransportButton(label: "⏮") {
                    playheadSeconds = 0
                }
                TransportButton(label: isPlaying ? "▌▌" : "▶") {
                    // 8a: visual only. The actual play loop wires at
                    // 8b/c when the engine's playback path lands the
                    // editor entry point.
                    isPlaying.toggle()
                }
                TransportButton(label: "⏭") {
                    playheadSeconds = duration
                }

                Spacer(minLength: 0)

                Text("\(formatTime(playheadSeconds)) / \(formatTime(duration))")
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg2)
            }

            ScrubBar(
                playheadSeconds: $playheadSeconds,
                duration: duration
            )
            .frame(height: 18)
        }
    }

    /// MM:SS for sub-hour macros, H:MM:SS for longer. Most v1 macros
    /// land under an hour; longer recordings get the wider format.
    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Scrub bar

/// Horizontal scrubber. Click anywhere on the track to jump; drag to
/// scrub. Maps drag position to time via the lane's pixel width and
/// the bundle's overall duration.
private struct ScrubBar: View {
    @Binding var playheadSeconds: Double
    let duration: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let safeDuration = max(duration, 0.001)
            let cursorX = clamp(
                CGFloat(playheadSeconds / safeDuration) * width,
                lower: 0,
                upper: width
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MacRoTheme.Color.laneBg)
                    .frame(height: 6)

                Capsule()
                    .fill(MacRoTheme.Color.brandCyan.opacity(0.6))
                    .frame(width: cursorX, height: 6)

                // Cursor knob.
                Circle()
                    .fill(MacRoTheme.Color.scrubCursor)
                    .frame(width: 12, height: 12)
                    .shadow(color: MacRoTheme.Color.scrubCursorGlow, radius: 4)
                    .position(x: cursorX, y: 9)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = clamp(value.location.x, lower: 0, upper: width)
                        playheadSeconds = Double(x / max(width, 1)) * duration
                    }
            )
        }
    }
}

// MARK: - Transport button

private struct TransportButton: View {
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .frame(width: 40, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .fill(MacRoTheme.Color.bgRaised.opacity(hovering ? 1.0 : 0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .strokeBorder(MacRoTheme.Color.laneBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
