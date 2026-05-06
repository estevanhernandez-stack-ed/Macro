// GatesLane.swift
// UI — GATES lane in the editor (item 8b).
//
// Renders ◇ POS (magenta) + ◆ IMG (cyan) markers from the timeline's
// `gate` events. Click a marker → selects it (binds back to the
// editor's selection state, populates the inspector panel).
//
// Pattern matches MoveLane / ActionsLane: GeometryReader + scale fn,
// playhead overlay last, no internal scroll. Clicks route via a
// closure injected by EditorView so the lane stays selection-agnostic.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 4
// (gate kind semantics) + § 5 (lane layout).

import SwiftUI

struct GatesLane: View {

    /// All visible gate events, mapped from the working state. We take
    /// `VisibleEvent` rather than raw timeline events so the lane can
    /// position markers on the compressed (post-cut) timeline without
    /// re-deriving cut math.
    let events: [VisibleEvent]
    let duration: Double
    let playheadSeconds: Double
    /// Currently selected event index (in the AUTHORITATIVE list).
    /// Used to highlight the matching marker.
    let selection: EventSelection?
    /// Click handler — invoked with the original-list index of the
    /// clicked gate. EditorView wires this to its `select()` flow.
    let onSelectGate: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let safeDuration = max(duration, 0.001)
            let scale: (Double) -> CGFloat = { CGFloat($0 / safeDuration) * width }

            let markers = events.compactMap { ve -> GateMarkerModel? in
                guard case .gate(let payload) = ve.event else { return nil }
                return GateMarkerModel(
                    originalIndex: ve.originalEventIndex,
                    compressedT: ve.compressedT,
                    kind: payload.gateKind,
                    ref: payload.ref
                )
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                    .fill(MacRoTheme.Color.laneBg)

                ForEach(markers) { marker in
                    let isSelected = selection?.originalEventIndex == marker.originalIndex
                    GateMarker(kind: marker.kind, isSelected: isSelected)
                        .help("\(marker.kind.rawValue.uppercased()) gate · \(marker.ref)")
                        .position(
                            x: clamp(scale(marker.compressedT), lower: 8, upper: max(width - 8, 8)),
                            y: MacRoTheme.Lane.gatesHeight / 2
                        )
                        .onTapGesture {
                            onSelectGate(marker.originalIndex)
                        }
                }

                // Playhead overlay — same magenta line as other lanes.
                Playhead()
                    .frame(width: 2)
                    .position(
                        x: clamp(scale(playheadSeconds), lower: 1, upper: max(width - 1, 1)),
                        y: MacRoTheme.Lane.gatesHeight / 2
                    )
            }
        }
        .frame(height: MacRoTheme.Lane.gatesHeight)
    }
}

// MARK: - Gate marker

private struct GateMarkerModel: Identifiable {
    /// Stable id derived from the original-list index so SwiftUI's
    /// ForEach diff doesn't churn on every render.
    var id: Int { originalIndex }
    let originalIndex: Int
    let compressedT: Double
    let kind: TimelineEvent.TimelineEventGateKind
    let ref: String
}

/// Visual treatment per spec § 4: POS (image-of-environment) reads
/// looser, rendered as an outline diamond in brand magenta. IMG
/// (image-of-UI) reads tighter, rendered as a filled diamond in brand
/// cyan. Selection ring is the productTeal CTA color so it doesn't
/// fight the duotone.
private struct GateMarker: View {
    let kind: TimelineEvent.TimelineEventGateKind
    let isSelected: Bool

    var body: some View {
        ZStack {
            // Selection ring — load-bearing visual: when the user is
            // editing a gate in the inspector, the ring on the lane is
            // the only "where am I editing?" affordance.
            if isSelected {
                Diamond()
                    .stroke(MacRoTheme.Color.gateSelectionRing, lineWidth: 2)
                    .frame(width: 18, height: 18)
            }
            switch kind {
            case .pos:
                // Outline diamond in magenta.
                Diamond()
                    .stroke(MacRoTheme.Color.brandMagenta, lineWidth: 2)
                    .frame(width: 12, height: 12)
            case .img:
                // Filled diamond in cyan.
                Diamond()
                    .fill(MacRoTheme.Color.brandCyan)
                    .frame(width: 12, height: 12)
            }
        }
        .contentShape(Rectangle().inset(by: -6)) // generous hit area
    }
}

/// 4-point diamond shape. SwiftUI has no built-in.
private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}
