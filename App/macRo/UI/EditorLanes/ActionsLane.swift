// ActionsLane.swift
// UI — ACTIONS lane in the editor (item 8a).
//
// Renders mouse clicks (•) and key/hotkey presses (boxed glyphs) at
// their absolute time on the timeline. Movement keys (WASD held
// duration + camera delta) are NOT in this lane — they live in the
// MOVE lane so the player can read movement intent at a glance.
//
// 8b wires selection: each marker carries the originalEventIndex of
// the event it represents. Tapping a marker invokes
// `onSelectEvent(originalEventIndex)` — EditorView routes that to its
// `select()` flow, which populates the inspector. Selected markers
// get a productTeal ring so the user sees WHICH dot or glyph they're
// editing.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + locked v2 mockup.

import SwiftUI

struct ActionsLane: View {

    /// Visible (post-cut, compressed) events. Same contract as the
    /// other lanes: positioning uses `compressedT`; selection routes
    /// through `originalEventIndex`.
    let events: [VisibleEvent]
    let duration: Double
    let playheadSeconds: Double
    /// Currently selected event index (in the AUTHORITATIVE list).
    /// Used to highlight the matching marker.
    let selection: EventSelection?
    /// Click handler — invoked with the original-list index of the
    /// clicked marker. EditorView wires this to its `select()` flow.
    let onSelectEvent: (Int) -> Void

    /// Movement keys are owned by MOVE lane; ACTIONS skips them.
    /// Keep the set in sync with MoveLane.moveKeys.
    private static let movementKeys: Set<String> = ["w", "a", "s", "d"]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let safeDuration = max(duration, 0.001)
            let scale: (Double) -> CGFloat = { CGFloat($0 / safeDuration) * width }

            let markers = makeMarkers()

            ZStack(alignment: .leading) {
                // Track background.
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                    .fill(MacRoTheme.Color.laneBg)

                ForEach(markers) { marker in
                    let isSelected = selection?.originalEventIndex == marker.originalEventIndex
                    ActionMarker(kind: marker.kind, isSelected: isSelected)
                        .position(
                            x: clamp(scale(marker.t), lower: 6, upper: max(width - 6, 6)),
                            y: MacRoTheme.Lane.actionsHeight / 2
                        )
                        .onTapGesture {
                            onSelectEvent(marker.originalEventIndex)
                        }
                }

                // Playhead overlay.
                Playhead()
                    .frame(width: 2)
                    .position(
                        x: clamp(scale(playheadSeconds), lower: 1, upper: max(width - 1, 1)),
                        y: MacRoTheme.Lane.actionsHeight / 2
                    )
            }
        }
        .frame(height: MacRoTheme.Lane.actionsHeight)
    }

    // MARK: - Marker shaping

    private func makeMarkers() -> [ActionMarkerModel] {
        var markers: [ActionMarkerModel] = []
        for ve in events {
            switch ve.event {
            case .click:
                markers.append(ActionMarkerModel(
                    t: ve.compressedT,
                    kind: .click,
                    originalEventIndex: ve.originalEventIndex
                ))
            case .keyPress(let payload):
                let key = payload.key.lowercased()
                if !Self.movementKeys.contains(key) {
                    markers.append(ActionMarkerModel(
                        t: ve.compressedT,
                        kind: .key(payload.key.uppercased()),
                        originalEventIndex: ve.originalEventIndex
                    ))
                }
            case .keyDown(let payload):
                // Non-movement keyDown events that don't pair with a
                // keyUp (e.g., hotkey taps captured as keyDown only)
                // also belong on ACTIONS. We deliberately render every
                // non-movement keyDown — duplicates with a paired keyUp
                // are visually fine because they collapse to a single
                // boxed glyph at the same x.
                let key = payload.key.lowercased()
                if !Self.movementKeys.contains(key) {
                    markers.append(ActionMarkerModel(
                        t: ve.compressedT,
                        kind: .key(payload.key.uppercased()),
                        originalEventIndex: ve.originalEventIndex
                    ))
                }
            default:
                continue
            }
        }
        return markers
    }
}

// MARK: - Marker model + view

private struct ActionMarkerModel: Identifiable {
    /// Stable id derived from the original-list index so SwiftUI's
    /// ForEach diff doesn't churn between renders. (A keyDown that
    /// happens to share a `t` with a paired keyUp gets a different
    /// originalEventIndex, so collisions don't happen in practice.)
    var id: Int { originalEventIndex }
    let t: Double
    let kind: ActionMarkerKind
    let originalEventIndex: Int
}

private enum ActionMarkerKind: Equatable {
    case click
    case key(String)
}

private struct ActionMarker: View {
    let kind: ActionMarkerKind
    let isSelected: Bool

    var body: some View {
        ZStack {
            switch kind {
            case .click:
                if isSelected {
                    Circle()
                        .stroke(MacRoTheme.Color.gateSelectionRing, lineWidth: 2)
                        .frame(width: 12, height: 12)
                }
                Circle()
                    .fill(MacRoTheme.Color.actionDot)
                    .frame(width: 6, height: 6)
            case .key(let label):
                Text(label)
                    .font(MacRoTheme.Font.monoMicro)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(MacRoTheme.Color.actionGlyphBg)
                    )
                    .overlay(
                        Group {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(MacRoTheme.Color.gateSelectionRing, lineWidth: 2)
                            }
                        }
                    )
            }
        }
        .contentShape(Rectangle().inset(by: -6)) // generous hit area
    }
}
