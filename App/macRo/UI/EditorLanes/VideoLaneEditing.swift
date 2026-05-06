// VideoLaneEditing.swift
// UI — editable VIDEO lane (item 8b).
//
// 8a's `VideoLane` is read-only — single kept blue segment, disabled
// cut handles, no click affordance. 8b promotes it: render a series of
// kept (blue) + cut (gray) bars derived from `cuts`, draw active
// drag-handles at every kept-segment edge, and accept clicks BETWEEN
// segments to add a new cut at that timestamp.
//
// Why a sibling file rather than editing VideoLane.swift directly:
// 8a's VideoLane is the read-only path used by tests and the script
// view (item 8c). Keeping it pristine + adding `EditableVideoLane`
// here lets 8b's edit affordances exist without bumping 8a's surface
// area. EditorView swaps to `EditableVideoLane` for the interactive
// path.
//
// Cut model: `WorkingState.cuts` (half-open [start, end) on the
// original timeline). The lane shows them in COMPRESSED space — i.e.,
// each cut is rendered as a thin gray "scar" between the surviving
// kept segments because compressed time has the cut content removed.
// This matches iMovie's "cutaway" affordance where the user sees the
// edit point without the cut content occupying timeline real estate.
//
// Click-to-cut UX: on a single click in a kept region, drop a 1.0s
// cut centered on the click point (clamped to the kept region's
// boundaries). The user refines via drag handles after.
//
// Drag handles: render at every cut boundary (left + right). Drag
// updates the cut range in real time; release commits an
// `EditorCommands.resizeCut` to the undo stack. Mid-drag mutations
// are LOCAL (don't flood the stack); commit on release.

import SwiftUI

struct EditableVideoLane: View {

    let state: WorkingState
    let playheadSeconds: Double
    /// Add a fresh cut. EditorView wraps this in
    /// `EditorCommands.addCut`.
    let onAddCut: (CutRange) -> Void
    /// Toggle (uncut) an existing cut. EditorView wraps in
    /// `EditorCommands.removeCut`.
    let onRemoveCut: (CutRange) -> Void
    /// Resize a cut on drag-release. EditorView wraps in
    /// `EditorCommands.resizeCut`.
    let onResizeCut: (UUID, Double, Double) -> Void

    /// Live drag preview — keyed by cut id, holds the in-progress
    /// (start, end). Cleared on drag-release.
    @State private var dragOverrides: [UUID: (Double, Double)] = [:]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let safeDuration = max(state.compressedDuration, 0.001)
            let scale: (Double) -> CGFloat = { CGFloat($0 / safeDuration) * width }

            // Build segments in compressed space. Walk the cuts in
            // ORIGINAL time order and translate to compressed via
            // `compressedTime`. A "cut" rendered visually is a thin
            // gray scar at the compressed boundary.
            let segments = compressedSegments()

            ZStack(alignment: .topLeading) {
                // Track background — gray base so kept segments lay on
                // top.
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                    .fill(MacRoTheme.Color.laneBg)

                // Kept segments (blue).
                ForEach(segments.kept) { seg in
                    keptSegment(seg: seg, width: width, scale: scale)
                }

                // Cut scars (thin gray vertical bands at compressed
                // positions). Click on a scar to uncut.
                ForEach(segments.scars) { scar in
                    cutScar(scar: scar, width: width, scale: scale)
                }

                // Drag handles at every kept-segment edge that has a
                // neighbor cut. We render two handles per cut (left
                // edge + right edge) keyed by cut id.
                ForEach(state.cuts) { cut in
                    cutHandles(cut: cut, width: width, scale: scale)
                }

                // Playhead.
                Playhead()
                    .frame(width: 2)
                    .position(
                        x: clamp(scale(playheadSeconds), lower: 1, upper: max(width - 1, 1)),
                        y: MacRoTheme.Lane.videoHeight / 2
                    )
            }
            .contentShape(Rectangle())
            // Click on a kept region (not on a scar / handle) to add a
            // 1s cut centered on the click point. We use a SpatialTap
            // gesture so SwiftUI gives us the location.
            .onTapGesture { location in
                guard width > 0 else { return }
                let compressedClick = Double(location.x / width) * safeDuration
                let clickOriginal = state.originalTime(fromCompressed: compressedClick)
                let halfWindow = 0.5
                let proposed = CutRange(
                    start: max(clickOriginal - halfWindow, 0),
                    end: clickOriginal + halfWindow
                )
                onAddCut(proposed)
            }
        }
        .frame(height: MacRoTheme.Lane.videoHeight)
    }

    // MARK: - Segment shaping

    /// Compressed-space segments. Kept segments are the blue spans;
    /// scars are the gray bands at compressed boundaries (each
    /// representing one cut on the original timeline).
    private func compressedSegments() -> CompressedSegments {
        let lastT = state.bundle.timeline.events.last.map(eventTime) ?? 0
        let totalOriginal = max(lastT + 0.5, 1.0)
        let totalCompressed = max(totalOriginal - state.totalCutDuration, 1.0)

        // Sort cuts and walk. A "kept span" lives between consecutive
        // cut boundaries.
        let sortedCuts = state.cuts.sorted { $0.start < $1.start }
        var kept: [KeptSegment] = []
        var scars: [CutScar] = []

        var cursorOrig: Double = 0
        var cursorComp: Double = 0
        for cut in sortedCuts {
            // Kept span: [cursorOrig ... cut.start] (compressed: same
            // length as original since no cut yet inside).
            let keepLen = max(cut.start - cursorOrig, 0)
            if keepLen > 0 {
                kept.append(KeptSegment(
                    compressedStart: cursorComp,
                    compressedEnd: cursorComp + keepLen
                ))
            }
            cursorComp += keepLen
            // Scar at cursorComp (zero-width on the compressed
            // timeline; render as a 4px-wide visual band centered
            // there).
            scars.append(CutScar(
                cutId: cut.id,
                compressedAt: cursorComp,
                originalCut: cut
            ))
            cursorOrig = cut.end
        }
        // Tail kept span.
        if cursorOrig < totalOriginal {
            let keepLen = totalOriginal - cursorOrig
            kept.append(KeptSegment(
                compressedStart: cursorComp,
                compressedEnd: cursorComp + keepLen
            ))
        }
        // Edge case: empty timeline — render a single kept span.
        if kept.isEmpty && scars.isEmpty {
            kept.append(KeptSegment(
                compressedStart: 0,
                compressedEnd: totalCompressed
            ))
        }
        return CompressedSegments(kept: kept, scars: scars)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func keptSegment(
        seg: KeptSegment,
        width: CGFloat,
        scale: (Double) -> CGFloat
    ) -> some View {
        let x = scale(seg.compressedStart)
        let w = max(scale(seg.compressedEnd) - x, 1)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(MacRoTheme.Color.videoKept)
            .frame(width: w, height: MacRoTheme.Lane.videoHeight - 4)
            .position(x: x + w / 2, y: MacRoTheme.Lane.videoHeight / 2)
    }

    @ViewBuilder
    private func cutScar(
        scar: CutScar,
        width: CGFloat,
        scale: (Double) -> CGFloat
    ) -> some View {
        let x = scale(scar.compressedAt)
        Rectangle()
            .fill(MacRoTheme.Color.videoCut)
            .frame(width: 4, height: MacRoTheme.Lane.videoHeight - 2)
            .overlay(
                // Thin diagonal hash so the user reads it as "cut" and
                // not "playhead." JetBrains-style 1px diagonal stroke.
                Rectangle()
                    .strokeBorder(MacRoTheme.Color.fg1.opacity(0.3), lineWidth: 0.5)
                    .frame(width: 4, height: MacRoTheme.Lane.videoHeight - 2)
            )
            .position(x: x, y: MacRoTheme.Lane.videoHeight / 2)
            // Click the scar to uncut.
            .onTapGesture {
                onRemoveCut(scar.originalCut)
            }
            .help("Cut · click to undo")
    }

    @ViewBuilder
    private func cutHandles(
        cut: CutRange,
        width: CGFloat,
        scale: (Double) -> CGFloat
    ) -> some View {
        let preview = dragOverrides[cut.id]
        let liveStart = preview?.0 ?? cut.start
        let liveEnd = preview?.1 ?? cut.end
        let scarComp = scale(state.compressedTime(liveStart))
        // Both handles render at the same compressed position (the
        // scar) — drag-left grows the cut to the left in original
        // coords, drag-right grows it to the right. Stack them at
        // small offsets so the user can grab either edge.
        let handleY = MacRoTheme.Lane.videoHeight / 2

        // Left edge handle (drag adjusts cut.start).
        EditableCutHandle()
            .frame(width: 8, height: MacRoTheme.Lane.videoHeight - 2)
            .position(x: scarComp - 4, y: handleY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard width > 0 else { return }
                        let safeDuration = max(state.compressedDuration, 0.001)
                        let dCompressed = Double(value.translation.width / width) * safeDuration
                        let proposedStart = max(liveStart + dCompressed, 0)
                        // Clamp: cut.start stays below cut.end.
                        let clamped = min(proposedStart, liveEnd - 0.05)
                        dragOverrides[cut.id] = (clamped, liveEnd)
                    }
                    .onEnded { _ in
                        if let (s, e) = dragOverrides[cut.id] {
                            onResizeCut(cut.id, s, e)
                            dragOverrides[cut.id] = nil
                        }
                    }
            )
        // Right edge handle (drag adjusts cut.end).
        EditableCutHandle()
            .frame(width: 8, height: MacRoTheme.Lane.videoHeight - 2)
            .position(x: scarComp + 4, y: handleY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard width > 0 else { return }
                        let safeDuration = max(state.compressedDuration, 0.001)
                        let dCompressed = Double(value.translation.width / width) * safeDuration
                        let proposedEnd = max(liveEnd + dCompressed, liveStart + 0.05)
                        dragOverrides[cut.id] = (liveStart, proposedEnd)
                    }
                    .onEnded { _ in
                        if let (s, e) = dragOverrides[cut.id] {
                            onResizeCut(cut.id, s, e)
                            dragOverrides[cut.id] = nil
                        }
                    }
            )
    }
}

// MARK: - Models

private struct KeptSegment: Identifiable {
    let id = UUID()
    let compressedStart: Double
    let compressedEnd: Double
}

private struct CutScar: Identifiable {
    let id = UUID()
    let cutId: UUID
    let compressedAt: Double
    let originalCut: CutRange
}

private struct CompressedSegments {
    let kept: [KeptSegment]
    let scars: [CutScar]
}

// MARK: - Active cut handle

/// Active drag handle — same shape as 8a's disabled CutHandle but at
/// full opacity + tinted in productTeal so the user sees "this is
/// grabbable." Cursor change to .resizeLeftRight on hover lands at
/// /iterate (NSCursor.push() requires AppKit hover plumbing).
private struct EditableCutHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(MacRoTheme.Color.videoHandle)
    }
}
