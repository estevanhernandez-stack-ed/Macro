// ActionsLane.swift
// UI — ACTIONS lane in the editor (item 8a).
//
// Renders mouse clicks (•) and key/hotkey presses (boxed glyphs) at
// their absolute time on the timeline. Movement keys (WASD held
// duration + camera delta) are NOT in this lane — they live in the
// MOVE lane so the player can read movement intent at a glance.
//
// Read-only in 8a. Clicking a marker would normally open the
// inspector at 8b; here it's a no-op.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + locked v2 mockup.

import SwiftUI

struct ActionsLane: View {

    let events: [TimelineEvent]
    let duration: Double
    let playheadSeconds: Double

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
                    ActionMarker(kind: marker.kind)
                        .position(
                            x: clamp(scale(marker.t), lower: 6, upper: max(width - 6, 6)),
                            y: MacRoTheme.Lane.actionsHeight / 2
                        )
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
        for event in events {
            switch event {
            case .click(let payload):
                markers.append(ActionMarkerModel(t: payload.t, kind: .click))
            case .keyPress(let payload):
                let key = payload.key.lowercased()
                if !Self.movementKeys.contains(key) {
                    markers.append(ActionMarkerModel(t: payload.t, kind: .key(payload.key.uppercased())))
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
                    markers.append(ActionMarkerModel(t: payload.t, kind: .key(payload.key.uppercased())))
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
    let id = UUID()
    let t: Double
    let kind: ActionMarkerKind
}

private enum ActionMarkerKind: Equatable {
    case click
    case key(String)
}

private struct ActionMarker: View {
    let kind: ActionMarkerKind

    var body: some View {
        switch kind {
        case .click:
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
        }
    }
}
