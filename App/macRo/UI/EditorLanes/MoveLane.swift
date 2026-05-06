// MoveLane.swift
// UI — MOVE lane in the editor (item 8a).
//
// Renders held-key movement bars (WASD) with duration visible, plus
// camera-delta bars (mouse-look). The v2 mockup is explicit about
// this lane being load-bearing: "the 3.5s walk to the fishing spot
// has to be visible, not a dot." Width = real time. A 0.4s tap and a
// 3.5s hold draw at proportionally different widths so the player
// can tell movement intent apart at a glance.
//
// 8b wires selection: each bar carries the originalEventIndex of the
// event it was derived from (keyDown for paired holds, keyPress for
// taps, cameraDelta for camera bars). Tapping a bar invokes
// `onSelectEvent(originalEventIndex)` — EditorView routes that to its
// `select()` flow which populates the inspector. Selected bars get a
// 2pt productTeal ring so the user can see WHICH bar they're editing.
//
// Pairing logic: a MOVE event is a `keyDown` followed by the matching
// `keyUp` at a later `t`. We zip these into "held" intervals at
// render time. Stray `keyDown` without `keyUp` (e.g., the recording
// stopped while a key was held) renders with the held duration
// extending to the end of the timeline. Selection-wise, the keyDown
// "owns" the bar — keyUp's index is irrelevant for selection.
//
// Camera deltas: each `cameraDelta` event has its own `duration`
// field (the engine smooths the delta over that span). We render
// each as a short blue bar at its `t`, width proportional to its
// duration, capped at a minimum so taps stay visible.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + locked v2 mockup.

import SwiftUI

struct MoveLane: View {

    /// Visible (post-cut, compressed) events. We take `VisibleEvent`
    /// rather than raw timeline events so the lane positions bars on
    /// the compressed timeline AND retains the original-list index
    /// needed for selection routing.
    let events: [VisibleEvent]
    let duration: Double
    let playheadSeconds: Double
    /// Currently selected event index (in the AUTHORITATIVE list).
    /// Used to highlight the bar whose originalEventIndex matches.
    let selection: EventSelection?
    /// Click handler — invoked with the original-list index of the
    /// event that "owns" the clicked bar (keyDown / keyPress /
    /// cameraDelta). EditorView wires this to its `select()` flow.
    let onSelectEvent: (Int) -> Void

    /// Set of keys we treat as "movement" for this lane. Anything else
    /// (numbers, hotkeys, etc.) routes to the ACTIONS lane. Lower-cased
    /// for comparison.
    private static let moveKeys: Set<String> = ["w", "a", "s", "d"]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let safeDuration = max(duration, 0.001)
            let scale: (Double) -> CGFloat = { CGFloat($0 / safeDuration) * width }

            let heldBars = makeHeldKeyBars()
            let cameraBars = makeCameraBars()

            ZStack(alignment: .topLeading) {
                // Track background.
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                    .fill(MacRoTheme.Color.laneBg)

                // Held-key bars (green).
                ForEach(heldBars) { bar in
                    let isSelected = selection?.originalEventIndex == bar.originalEventIndex
                    HeldKeyBar(label: barLabel(for: bar), isSelected: isSelected)
                        .frame(
                            width: max(scale(bar.duration), MacRoTheme.Lane.minBarWidth),
                            height: MacRoTheme.Lane.moveHeight - 6
                        )
                        .position(
                            x: scale(bar.start) + max(scale(bar.duration), MacRoTheme.Lane.minBarWidth) / 2,
                            y: MacRoTheme.Lane.moveHeight / 2
                        )
                        .onTapGesture {
                            onSelectEvent(bar.originalEventIndex)
                        }
                }

                // Camera-delta bars (blue accent).
                ForEach(cameraBars) { bar in
                    let isSelected = selection?.originalEventIndex == bar.originalEventIndex
                    CameraBar(isSelected: isSelected)
                        .frame(
                            width: max(scale(bar.duration), MacRoTheme.Lane.minBarWidth),
                            height: MacRoTheme.Lane.moveHeight - 10
                        )
                        .position(
                            x: scale(bar.start) + max(scale(bar.duration), MacRoTheme.Lane.minBarWidth) / 2,
                            y: MacRoTheme.Lane.moveHeight / 2
                        )
                        .onTapGesture {
                            onSelectEvent(bar.originalEventIndex)
                        }
                }

                // Playhead overlay.
                Playhead()
                    .frame(width: 2)
                    .position(
                        x: clamp(scale(playheadSeconds), lower: 1, upper: max(width - 1, 1)),
                        y: MacRoTheme.Lane.moveHeight / 2
                    )
            }
        }
        .frame(height: MacRoTheme.Lane.moveHeight)
    }

    // MARK: - Bar shaping

    /// Pair `keyDown` with the next `keyUp` for the same WASD key.
    /// Stray `keyDown` (no matching `keyUp`) extends to the end of
    /// the timeline — common for "user hit stop while still holding W."
    /// Each bar carries the keyDown's (or keyPress's) originalEventIndex
    /// so taps route selection back to the right authoritative event.
    private func makeHeldKeyBars() -> [HeldKey] {
        var bars: [HeldKey] = []
        // key (lower) -> (start time, originalEventIndex of the keyDown
        // that opened this hold). We carry the index forward so the
        // resulting bar can attribute selection to the keyDown.
        var openHolds: [String: (start: Double, originalIndex: Int)] = [:]

        for ve in events {
            switch ve.event {
            case .keyDown(let payload):
                let key = payload.key.lowercased()
                guard Self.moveKeys.contains(key) else { continue }
                openHolds[key] = (ve.compressedT, ve.originalEventIndex)
            case .keyUp(let payload):
                let key = payload.key.lowercased()
                guard Self.moveKeys.contains(key) else { continue }
                if let open = openHolds.removeValue(forKey: key) {
                    bars.append(HeldKey(
                        key: key,
                        start: open.start,
                        duration: max(ve.compressedT - open.start, 0.0),
                        originalEventIndex: open.originalIndex
                    ))
                }
            case .keyPress(let payload):
                // keyPress is "tap" — render as a short held bar
                // (50ms baseline) so single WASD taps still appear.
                let key = payload.key.lowercased()
                if Self.moveKeys.contains(key) {
                    bars.append(HeldKey(
                        key: key,
                        start: ve.compressedT,
                        duration: 0.05,
                        originalEventIndex: ve.originalEventIndex
                    ))
                }
            default:
                continue
            }
        }
        // Flush any open holds — extend to end of timeline.
        for (key, open) in openHolds {
            bars.append(HeldKey(
                key: key,
                start: open.start,
                duration: max(duration - open.start, 0.05),
                originalEventIndex: open.originalIndex
            ))
        }
        return bars
    }

    private func makeCameraBars() -> [CameraIntent] {
        var bars: [CameraIntent] = []
        for ve in events {
            if case .cameraDelta(let payload) = ve.event {
                // Many cameraDelta events have duration 0 (single-frame
                // deltas); render those as min-width chips.
                let dur = max(payload.duration, 0.05)
                bars.append(CameraIntent(
                    start: ve.compressedT,
                    duration: dur,
                    originalEventIndex: ve.originalEventIndex
                ))
            }
        }
        return bars
    }

    private func barLabel(for bar: HeldKey) -> String {
        let keyUpper = bar.key.uppercased()
        if bar.duration >= 0.5 {
            return "\(keyUpper) · \(formatSeconds(bar.duration))"
        }
        return keyUpper
    }

    private func formatSeconds(_ s: Double) -> String {
        if s >= 1.0 {
            return String(format: "%.1fs", s)
        } else {
            return String(format: ".%ds", Int((s * 10).rounded()))
        }
    }
}

// MARK: - Bar models

private struct HeldKey: Identifiable {
    /// Use the originating event's original index as the SwiftUI id so
    /// re-renders don't churn the bar identity (a UUID per render would
    /// reset selection-ring animations on every command apply).
    var id: Int { originalEventIndex }
    let key: String
    let start: Double
    let duration: Double
    let originalEventIndex: Int
}

private struct CameraIntent: Identifiable {
    var id: Int { originalEventIndex }
    let start: Double
    let duration: Double
    let originalEventIndex: Int
}

// MARK: - Bar views

private struct HeldKeyBar: View {
    let label: String
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(MacRoTheme.Color.moveKey)
                .overlay(
                    Text(label)
                        .font(MacRoTheme.Font.monoMicro)
                        .foregroundStyle(MacRoTheme.Color.fg1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4),
                    alignment: .leading
                )
            // Selection ring — productTeal to match GatesLane / VIDEO
            // handles. 2pt outline so it reads against the green fill
            // without redrawing the bar's body.
            if isSelected {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(MacRoTheme.Color.gateSelectionRing, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct CameraBar: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(MacRoTheme.Color.moveCamera)
                .opacity(0.85)
            if isSelected {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(MacRoTheme.Color.gateSelectionRing, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}
