// VideoLane.swift
// UI — VIDEO lane in the editor (item 8a).
//
// Read-only in 8a: renders a single full-width "kept" segment (blue)
// because no cuts have been authored yet. The cut-handle affordance
// is rendered visible-but-disabled at each segment edge so the user
// sees what cut points will look like; clicking does nothing in 8a
// (8b wires the drag handlers).
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + locked v2 mockup. Cuts compress playback time, not stretch — the
// kept blue regions are the only thing the engine plays.

import SwiftUI

struct VideoLane: View {

    /// Macro duration in seconds — used to position the playhead
    /// indicator. The lane bar itself is full-width because a kept
    /// region with no cuts spans the whole timeline.
    let duration: Double

    /// Current scrub time. Drives the playhead overlay.
    let playheadSeconds: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let safeDuration = max(duration, 0.001)
            let playheadX = width * (playheadSeconds / safeDuration)

            ZStack(alignment: .leading) {
                // Lane track — currently a single kept segment. Once
                // 8b lands cut operations, this becomes a series of
                // kept (blue) + cut (gray) bars laid horizontally.
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                    .fill(MacRoTheme.Color.videoKept)

                // Cut-handle affordance at the right edge — visible
                // but disabled in 8a. Hint to the user that drag-trim
                // will live here at 8b.
                CutHandle()
                    .frame(width: 6)
                    .position(x: max(width - 3, 0), y: MacRoTheme.Lane.videoHeight / 2)
                    .opacity(0.45)

                // Playhead overlay — magenta line that cuts across all
                // four lanes. Owned per-lane (rather than a single
                // overlay across the lane stack) because each lane's
                // GeometryReader knows its own width independently.
                Playhead()
                    .frame(width: 2)
                    .position(x: clamp(playheadX, lower: 1, upper: max(width - 1, 1)),
                              y: MacRoTheme.Lane.videoHeight / 2)
            }
        }
        .frame(height: MacRoTheme.Lane.videoHeight)
    }
}

/// Visible-but-disabled cut handle — the affordance at a kept-segment
/// edge that says "you'll drag here to trim." 8b wires the drag.
private struct CutHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(MacRoTheme.Color.fg1.opacity(0.6))
    }
}

/// Magenta playhead line. Lane-local so it tracks the lane's own
/// width. Spec § 8 calls for cyan/magenta paired surfaces; magenta
/// reads strongest against the blue VIDEO + green MOVE bars.
struct Playhead: View {
    var body: some View {
        Rectangle()
            .fill(MacRoTheme.Color.scrubCursor)
            .shadow(color: MacRoTheme.Color.scrubCursorGlow, radius: 4, x: 0, y: 0)
    }
}

/// Inline clamp — Swift's built-in `clamped(to:)` is iOS-15+ but
/// dropped on macOS 14, so we keep this trivial helper local.
func clamp<T: Comparable>(_ v: T, lower: T, upper: T) -> T {
    min(max(v, lower), upper)
}
