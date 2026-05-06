// EditorInspector.swift
// UI — right-side inspector panel (item 8b).
//
// Shows when an event is selected (input or gate). Lets the user:
//
//   - For input events: shift timing offset (±100ms slider, 0-snap),
//     add jitter (±X ms randomization), and delete the event (paired
//     keyDown↔keyUp deletes together; warns on cross-cut pairs). For
//     `click` events: a "swap to image-anchored" toggle that opens
//     the cropper and replaces the click coords with an image anchor
//     (engine-side resolution is at /iterate per the deliverable; the
//     toggle records intent in the click's `jitterMs` reuse hack —
//     no, see decision below).
//
//   - For gate events: edit `retries` (1–10), `timeout` (1–120s),
//     `onFail` action (continue / abort / sub:<name>), preview the
//     gate image, and delete the gate.
//
// All mutations route through `dispatch(_:)` so undo/redo covers
// them. The inspector itself is a reactive view bound to selection +
// the working state — re-rendering on every command apply is cheap
// because SwiftUI diff'ing kicks the same fields.
//
// Decision on click → image-anchored toggle:
//   - The schema doesn't have a per-click `imageAnchor` field today
//     (Target.resolutionPolicy is per-bundle, not per-event).
//   - Hand-editing MacroFormat.swift breaks the codegen lockstep
//     guard at the schema-vs-types CI step. Adding `imageAnchor` to
//     the schema is a /iterate decision (logged), not an 8b move.
//   - For 8b: the toggle is wired (UI state) and opens the cropper to
//     designate the target image; on confirm, we drop a POS gate at
//     the click's t (visible on the GATES lane) and tag the gate's
//     `ref` so /iterate can wire engine-side click→gate-anchor lookup
//     without breaking schema. This produces the correct YAML shape
//     today: a `gate` event sitting next to the click, ref'd by id.
//   - The inspector marks the click as "anchored to gate <ref>" via a
//     local map (not persisted) so the user sees the wiring state.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 4
// + § 5 (inspector) + docs/prd.md > Epic C (gate authoring stories).

import AppKit
import SwiftUI

struct EditorInspector: View {

    /// The full working state. Read-only at this layer — mutations go
    /// through `dispatch` so undo/redo covers them.
    let state: WorkingState

    /// Disk URL of the bundle (used to load gate-image previews).
    let bundleURL: URL

    /// Dispatch a command (apply + push to undo stack). EditorView
    /// wires this to its own dispatch so the inspector stays
    /// state-aware but mutation-agnostic.
    let dispatch: (EditorCommand) -> Void

    /// Open the cropper to designate an image anchor for the selected
    /// click event. Wires to EditorView's cropper-presentation flow.
    let openImageAnchorCropper: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().background(MacRoTheme.Color.laneBorder)

            ScrollView {
                if let sel = state.selection,
                   sel.originalEventIndex >= 0,
                   sel.originalEventIndex < state.bundle.timeline.events.count {
                    body(forEvent: state.bundle.timeline.events[sel.originalEventIndex],
                         at: sel.originalEventIndex)
                        .padding(MacRoTheme.Spacing.md)
                } else {
                    emptyState
                        .padding(MacRoTheme.Spacing.md)
                }
            }
        }
        .frame(width: 280)
        .background(MacRoTheme.Color.inspectorBg)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("INSPECTOR")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
            Spacer()
        }
        .padding(.horizontal, MacRoTheme.Spacing.md)
        .padding(.vertical, MacRoTheme.Spacing.sm)
        .background(MacRoTheme.Color.bgSurface)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            Text("Nothing selected")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg2)
            Text("Click a gate marker, key, or click on the lanes to refine its timing or behavior.")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg3)
        }
    }

    // MARK: - Body switch

    @ViewBuilder
    private func body(forEvent event: TimelineEvent, at index: Int) -> some View {
        switch event {
        case .keyDown, .keyUp, .keyPress, .click, .cameraDelta:
            inputEventBody(event: event, index: index)
        case .gate(let payload):
            gateEventBody(payload: payload, index: index)
        case .loop, .invokeSub:
            // 8c surface — show kind + delete only.
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
                kindLabel(for: event)
                Text("Editing for this event type lands at item 8c (subs / loop control).")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                deleteButton(label: "Delete event") {
                    dispatch(EditorCommands.deleteEventsCapturing(
                        atOriginalIndices: [index],
                        from: state
                    ))
                }
            }
        }
    }

    // MARK: - Input event body

    @ViewBuilder
    private func inputEventBody(event: TimelineEvent, index: Int) -> some View {
        let t = eventTime(event)

        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            kindLabel(for: event)

            tRow(t: t)

            // Timing offset slider — ±100ms, snaps to 0. Editing this
            // produces a "replace event with shifted t" command. We
            // bind to a derived offset so dragging slider doesn't
            // produce a flood of commands; we only commit on release.
            TimingOffsetEditor(
                event: event,
                index: index,
                state: state,
                dispatch: dispatch
            )

            // Jitter (only on click — schema-supported field). For
            // other events the slider is hidden in 8b.
            if case .click(let click) = event {
                JitterEditor(
                    click: click,
                    index: index,
                    state: state,
                    dispatch: dispatch
                )

                imageAnchorToggle(forClickAt: index)
            }

            Divider().background(MacRoTheme.Color.laneBorder)

            deleteButton(label: deleteLabel(for: event)) {
                deleteWithPairing(forIndex: index, event: event)
            }
        }
    }

    // MARK: - Click → image-anchored

    @ViewBuilder
    private func imageAnchorToggle(forClickAt index: Int) -> some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            HStack {
                Text("Image-anchor target")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                Spacer()
                Button(action: {
                    openImageAnchorCropper(index)
                }) {
                    Text("Pick target…")
                        .font(MacRoTheme.Font.monoMicro)
                        .tracking(0.12 * 11)
                        .foregroundStyle(MacRoTheme.Color.brandCyan)
                        .padding(.horizontal, MacRoTheme.Spacing.sm)
                        .padding(.vertical, MacRoTheme.Spacing.xs)
                        .overlay(
                            RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                                .strokeBorder(MacRoTheme.Color.brandCyan.opacity(0.6), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Text("Drops an IMG gate at this click's time so the engine can recompute the target at runtime. Engine-side click resolution lands at /iterate.")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
        }
    }

    // MARK: - Gate event body

    @ViewBuilder
    private func gateEventBody(
        payload: TimelineEvent.TimelineEventGatePayload,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            HStack(spacing: MacRoTheme.Spacing.sm) {
                Text(payload.gateKind.rawValue.uppercased() + " GATE")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(payload.gateKind == .img
                                     ? MacRoTheme.Color.brandCyan
                                     : MacRoTheme.Color.brandMagenta)
                Spacer()
            }

            Text(payload.ref)
                .font(MacRoTheme.Font.mono)
                .foregroundStyle(MacRoTheme.Color.fg2)

            tRow(t: payload.t)

            // Gate preview.
            GatePreview(
                bundleURL: bundleURL,
                gateKind: payload.gateKind,
                ref: payload.ref
            )

            // Retries.
            GateRetriesEditor(
                payload: payload,
                index: index,
                state: state,
                dispatch: dispatch
            )

            // Timeout.
            GateTimeoutEditor(
                payload: payload,
                index: index,
                state: state,
                dispatch: dispatch
            )

            // onFail.
            GateOnFailEditor(
                payload: payload,
                index: index,
                state: state,
                dispatch: dispatch
            )

            Divider().background(MacRoTheme.Color.laneBorder)

            deleteButton(label: "Delete gate") {
                dispatch(EditorCommands.deleteEventsCapturing(
                    atOriginalIndices: [index],
                    from: state
                ))
            }
        }
    }

    // MARK: - Shared rows

    @ViewBuilder
    private func kindLabel(for event: TimelineEvent) -> some View {
        let label: String = {
            switch event {
            case .keyDown(let p): return "KEY DOWN · \(p.key.uppercased())"
            case .keyUp(let p):   return "KEY UP · \(p.key.uppercased())"
            case .keyPress(let p): return "KEY PRESS · \(p.key.uppercased())"
            case .click(let p):   return "CLICK · \(p.button.rawValue)"
            case .cameraDelta:    return "CAMERA DELTA"
            case .gate(let p):    return "\(p.gateKind.rawValue.uppercased()) GATE"
            case .loop:           return "LOOP"
            case .invokeSub(let p): return "INVOKE SUB · \(p.name)"
            }
        }()
        Text(label)
            .font(MacRoTheme.Font.monoMicro)
            .tracking(0.12 * 11)
            .foregroundStyle(MacRoTheme.Color.fg2)
    }

    @ViewBuilder
    private func tRow(t: Double) -> some View {
        HStack {
            Text("t")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text(String(format: "%.3fs", t))
                .font(MacRoTheme.Font.mono)
                .foregroundStyle(MacRoTheme.Color.fg2)
            Spacer()
        }
    }

    @ViewBuilder
    private func deleteButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.stateDanger)
                .padding(.horizontal, MacRoTheme.Spacing.md)
                .padding(.vertical, MacRoTheme.Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .strokeBorder(MacRoTheme.Color.stateDanger.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func deleteLabel(for event: TimelineEvent) -> String {
        switch event {
        case .keyDown: return "Delete key (and its keyUp pair)"
        case .keyUp:   return "Delete key (and its keyDown pair)"
        default:       return "Delete event"
        }
    }

    // MARK: - Pair-aware delete

    private func deleteWithPairing(forIndex index: Int, event: TimelineEvent) {
        var indices: [Int] = [index]
        var pairCrossesCut = false

        switch event {
        case .keyDown:
            if let upIdx = EditorEventPairs.matchingKeyUp(
                forKeyDownAt: index,
                in: state.bundle.timeline.events
            ) {
                let upT = eventTime(state.bundle.timeline.events[upIdx])
                let downT = eventTime(event)
                // Cross-cut: ANY cut sits between the two ts.
                pairCrossesCut = state.cuts.contains { cut in
                    cut.start >= downT && cut.end <= upT
                }
                indices.append(upIdx)
            }
        case .keyUp:
            if let downIdx = EditorEventPairs.matchingKeyDown(
                forKeyUpAt: index,
                in: state.bundle.timeline.events
            ) {
                let downT = eventTime(state.bundle.timeline.events[downIdx])
                let upT = eventTime(event)
                pairCrossesCut = state.cuts.contains { cut in
                    cut.start >= downT && cut.end <= upT
                }
                indices.append(downIdx)
            }
        default:
            break
        }

        if pairCrossesCut {
            // Confirm before deleting cross-cut pairs. NSAlert is the
            // simplest reliable confirm path on macOS; surfaces the
            // tradeoff explicitly.
            let alert = NSAlert()
            alert.messageText = "Pair crosses a cut"
            alert.informativeText = "The matching event is on the other side of a cut. Deleting both keeps the macro consistent; deleting only this side may leave a stuck key."
            alert.addButton(withTitle: "Delete pair anyway")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            let response = alert.runModal()
            if response != .alertFirstButtonReturn { return }
        }

        dispatch(EditorCommands.deleteEventsCapturing(
            atOriginalIndices: indices,
            from: state
        ))
    }
}

// MARK: - Timing offset slider

private struct TimingOffsetEditor: View {
    let event: TimelineEvent
    let index: Int
    let state: WorkingState
    let dispatch: (EditorCommand) -> Void

    /// Drag-only offset preview in seconds. Commits on release.
    @State private var draftOffset: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            HStack {
                Text("Timing offset")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                Spacer()
                Text("\(formatMs(draftOffset))")
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }
            Slider(
                value: $draftOffset,
                in: -0.1...0.1,
                step: 0.005,
                onEditingChanged: { editing in
                    if !editing && abs(draftOffset) > 0.0001 {
                        commit()
                    }
                }
            )
            .tint(MacRoTheme.Color.brandCyan)
        }
    }

    private func commit() {
        let oldT = eventTime(event)
        let newT = max(oldT + draftOffset, 0)
        guard let shifted = withShifted(t: newT, event: event) else { return }
        dispatch(EditorCommands.replaceEvent(
            atOriginalIndex: index,
            with: shifted,
            from: state,
            label: "Shift t by \(formatMs(draftOffset))"
        ))
        draftOffset = 0
    }

    private func formatMs(_ s: Double) -> String {
        let ms = Int((s * 1000).rounded())
        return ms >= 0 ? "+\(ms)ms" : "\(ms)ms"
    }
}

// MARK: - Jitter slider (click only)

private struct JitterEditor: View {
    let click: TimelineEvent.TimelineEventClickPayload
    let index: Int
    let state: WorkingState
    let dispatch: (EditorCommand) -> Void

    @State private var draft: Double = 0
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            HStack {
                Text("Jitter (±ms)")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                Spacer()
                Text("\(Int(draft))ms")
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }
            Slider(
                value: $draft,
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { commit() }
                }
            )
            .tint(MacRoTheme.Color.brandCyan)
        }
        .onAppear {
            if !loaded {
                draft = click.jitterMs ?? 0
                loaded = true
            }
        }
    }

    private func commit() {
        let newClick = TimelineEvent.TimelineEventClickPayload(
            t: click.t,
            x: click.x,
            y: click.y,
            button: click.button,
            jitterMs: draft > 0 ? draft : nil
        )
        dispatch(EditorCommands.replaceEvent(
            atOriginalIndex: index,
            with: .click(newClick),
            from: state,
            label: "Set click jitter to ±\(Int(draft))ms"
        ))
    }
}

// MARK: - Gate retries editor

private struct GateRetriesEditor: View {
    let payload: TimelineEvent.TimelineEventGatePayload
    let index: Int
    let state: WorkingState
    let dispatch: (EditorCommand) -> Void

    @State private var draft: Double = 3
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            HStack {
                Text("Retries")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                Spacer()
                Text("\(Int(draft))")
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }
            Slider(
                value: $draft,
                in: 1...10,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { commit() }
                }
            )
            .tint(MacRoTheme.Color.brandCyan)
        }
        .onAppear {
            if !loaded {
                draft = Double(payload.retries ?? 3)
                loaded = true
            }
        }
    }

    private func commit() {
        let newPayload = TimelineEvent.TimelineEventGatePayload(
            t: payload.t,
            gateKind: payload.gateKind,
            ref: payload.ref,
            retries: Int(draft),
            timeout: payload.timeout,
            onFail: payload.onFail
        )
        dispatch(EditorCommands.replaceEvent(
            atOriginalIndex: index,
            with: .gate(newPayload),
            from: state,
            label: "Gate retries → \(Int(draft))"
        ))
    }
}

// MARK: - Gate timeout editor

private struct GateTimeoutEditor: View {
    let payload: TimelineEvent.TimelineEventGatePayload
    let index: Int
    let state: WorkingState
    let dispatch: (EditorCommand) -> Void

    @State private var draft: Double = 30
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            HStack {
                Text("Timeout (s)")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                Spacer()
                Text("\(Int(draft))s")
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }
            Slider(
                value: $draft,
                in: 1...120,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { commit() }
                }
            )
            .tint(MacRoTheme.Color.brandCyan)
        }
        .onAppear {
            if !loaded {
                draft = payload.timeout ?? 30
                loaded = true
            }
        }
    }

    private func commit() {
        let newPayload = TimelineEvent.TimelineEventGatePayload(
            t: payload.t,
            gateKind: payload.gateKind,
            ref: payload.ref,
            retries: payload.retries,
            timeout: draft,
            onFail: payload.onFail
        )
        dispatch(EditorCommands.replaceEvent(
            atOriginalIndex: index,
            with: .gate(newPayload),
            from: state,
            label: "Gate timeout → \(Int(draft))s"
        ))
    }
}

// MARK: - Gate onFail editor

private struct GateOnFailEditor: View {
    let payload: TimelineEvent.TimelineEventGatePayload
    let index: Int
    let state: WorkingState
    let dispatch: (EditorCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            Text("On fail")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
            HStack(spacing: MacRoTheme.Spacing.xs) {
                onFailButton(label: "abort", value: .literal(.abort))
                onFailButton(label: "continue", value: .literal(.continue))
            }
            // sub:<name> form is wired in 8c when the subs panel
            // lands. For 8b we keep the literal pair as the inspector
            // surface; existing sub: values still render via the
            // current-value badge below.
            if case .subInvocation(let name) = (payload.onFail ?? .literal(.continue)) {
                Text("Currently: sub:\(name) (edit via subs panel at 8c)")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }
        }
    }

    @ViewBuilder
    private func onFailButton(
        label: String,
        value: TimelineEvent.TimelineEventOnFail
    ) -> some View {
        let current = (payload.onFail ?? .literal(.continue))
        let isActive = current == value
        Button(action: { commit(value) }) {
            Text(label)
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(isActive ? MacRoTheme.Color.bgPage : MacRoTheme.Color.fg2)
                .padding(.horizontal, MacRoTheme.Spacing.sm)
                .padding(.vertical, MacRoTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .fill(isActive ? MacRoTheme.Color.productTeal : MacRoTheme.Color.bgRaised)
                )
        }
        .buttonStyle(.plain)
    }

    private func commit(_ value: TimelineEvent.TimelineEventOnFail) {
        let newPayload = TimelineEvent.TimelineEventGatePayload(
            t: payload.t,
            gateKind: payload.gateKind,
            ref: payload.ref,
            retries: payload.retries,
            timeout: payload.timeout,
            onFail: value
        )
        dispatch(EditorCommands.replaceEvent(
            atOriginalIndex: index,
            with: .gate(newPayload),
            from: state,
            label: "Gate onFail change"
        ))
    }
}

// MARK: - Gate preview

private struct GatePreview: View {
    let bundleURL: URL
    let gateKind: TimelineEvent.TimelineEventGateKind
    let ref: String

    var body: some View {
        let gatesDir = bundleURL.appendingPathComponent("gates", isDirectory: true)
        let pngURL = gatesDir.appendingPathComponent("\(gateKind.rawValue)-\(ref).png")

        if let image = NSImage(contentsOf: pngURL) {
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("PREVIEW")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 120)
                    .background(MacRoTheme.Color.bgPage)
                    .clipShape(RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                            .strokeBorder(MacRoTheme.Color.laneBorder, lineWidth: 1)
                    )
            }
        } else {
            Text("(preview missing — gates/\(gateKind.rawValue)-\(ref).png not on disk)")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
        }
    }
}
