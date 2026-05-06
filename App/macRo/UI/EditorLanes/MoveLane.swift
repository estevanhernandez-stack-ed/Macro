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
// Read-only in 8a — no drag-to-edit, no inspector wiring. Clicking a
// bar would normally open the inspector at 8b; here it's a no-op.
//
// Pairing logic: a MOVE event is a `keyDown` followed by the matching
// `keyUp` at a later `t`. We zip these into "held" intervals at
// render time. Stray `keyDown` without `keyUp` (e.g., the recording
// stopped while a key was held) renders with the held duration
// extending to the end of the timeline.
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

    let events: [TimelineEvent]
    let duration: Double
    let playheadSeconds: Double

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
                    HeldKeyBar(label: barLabel(for: bar))
                        .frame(
                            width: max(scale(bar.duration), MacRoTheme.Lane.minBarWidth),
                            height: MacRoTheme.Lane.moveHeight - 6
                        )
                        .position(
                            x: scale(bar.start) + max(scale(bar.duration), MacRoTheme.Lane.minBarWidth) / 2,
                            y: MacRoTheme.Lane.moveHeight / 2
                        )
                }

                // Camera-delta bars (blue accent).
                ForEach(cameraBars) { bar in
                    CameraBar()
                        .frame(
                            width: max(scale(bar.duration), MacRoTheme.Lane.minBarWidth),
                            height: MacRoTheme.Lane.moveHeight - 10
                        )
                        .position(
                            x: scale(bar.start) + max(scale(bar.duration), MacRoTheme.Lane.minBarWidth) / 2,
                            y: MacRoTheme.Lane.moveHeight / 2
                        )
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
    private func makeHeldKeyBars() -> [HeldKey] {
        var bars: [HeldKey] = []
        var openHolds: [String: Double] = [:] // key (lower) -> start time

        for event in events {
            switch event {
            case .keyDown(let payload):
                let key = payload.key.lowercased()
                guard Self.moveKeys.contains(key) else { continue }
                openHolds[key] = payload.t
            case .keyUp(let payload):
                let key = payload.key.lowercased()
                guard Self.moveKeys.contains(key) else { continue }
                if let start = openHolds.removeValue(forKey: key) {
                    bars.append(HeldKey(
                        key: key,
                        start: start,
                        duration: max(payload.t - start, 0.0)
                    ))
                }
            case .keyPress(let payload):
                // keyPress is "tap" — render as a short held bar
                // (50ms baseline) so single WASD taps still appear.
                let key = payload.key.lowercased()
                if Self.moveKeys.contains(key) {
                    bars.append(HeldKey(
                        key: key,
                        start: payload.t,
                        duration: 0.05
                    ))
                }
            default:
                continue
            }
        }
        // Flush any open holds — extend to end of timeline.
        for (key, start) in openHolds {
            bars.append(HeldKey(
                key: key,
                start: start,
                duration: max(duration - start, 0.05)
            ))
        }
        return bars
    }

    private func makeCameraBars() -> [CameraIntent] {
        var bars: [CameraIntent] = []
        for event in events {
            if case .cameraDelta(let payload) = event {
                // Many cameraDelta events have duration 0 (single-frame
                // deltas); render those as min-width chips.
                let dur = max(payload.duration, 0.05)
                bars.append(CameraIntent(start: payload.t, duration: dur))
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
    let id = UUID()
    let key: String
    let start: Double
    let duration: Double
}

private struct CameraIntent: Identifiable {
    let id = UUID()
    let start: Double
    let duration: Double
}

// MARK: - Bar views

private struct HeldKeyBar: View {
    let label: String

    var body: some View {
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
    }
}

private struct CameraBar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(MacRoTheme.Color.moveCamera)
            .opacity(0.85)
    }
}
