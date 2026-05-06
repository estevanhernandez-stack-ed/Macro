// StopOnPanel.swift
// UI — toolbar sheet for managing stopOn[] interrupt triggers (item 8c).
//
// stopOn triggers fire in parallel with the run loop (engine polls
// every 500ms — spec § 6). When `when` matches an on-screen image,
// the engine takes `action` (pause / exit / sub:<name>).
//
// The panel surfaces:
//   - Each trigger as a row with editable fields (gateKind, ref,
//     action, message)
//   - "+ Add trigger" inserts a default img-gate / pause trigger
//   - Per-row delete
//
// All mutations route through `dispatch(EditorCommands.replaceStopOn)`
// so undo/redo covers them. Visual treatment via MacRoTheme.

import SwiftUI

struct StopOnPanel: View {

    let state: WorkingState
    let dispatch: (EditorCommand) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            header

            Divider().background(MacRoTheme.Color.laneBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
                    if currentTriggers.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(currentTriggers.enumerated()), id: \.offset) { idx, trig in
                            row(index: idx, trigger: trig)
                        }
                    }
                }
                .padding(MacRoTheme.Spacing.md)
            }
            .background(MacRoTheme.Color.bgPage)
            .clipShape(RoundedRectangle(cornerRadius: MacRoTheme.Radius.md))

            Divider().background(MacRoTheme.Color.laneBorder)

            HStack {
                pillButton(label: "+ Add trigger", action: addTrigger)
                Spacer()
                Button(action: onClose) {
                    Text("Close")
                        .font(MacRoTheme.Font.bodySmall)
                        .foregroundStyle(MacRoTheme.Color.bgPage)
                        .padding(.horizontal, MacRoTheme.Spacing.md)
                        .padding(.vertical, MacRoTheme.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                                .fill(MacRoTheme.Color.productTeal)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MacRoTheme.Spacing.lg)
        .frame(width: 620, height: 520)
        .background(MacRoTheme.Color.bgSurface)
    }

    // MARK: - Computed

    private var currentTriggers: [StopOnTrigger] {
        state.bundle.timeline.stopOn ?? []
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("STOPON")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("·")
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("interrupt triggers (\(currentTriggers.count)) — polled every 500ms in parallel with the run loop")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
            Spacer()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            Text("No stopOn triggers yet")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg2)
            Text("Add a trigger to interrupt the macro on a UI cue (e.g., \"Mythic\" badge → pause). Each trigger names the gate image and the action to take when the engine sees it.")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg3)
        }
    }

    @ViewBuilder
    private func row(index: Int, trigger: StopOnTrigger) -> some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            HStack {
                Text("#\(index + 1)")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                Spacer()
                pillButton(label: "Delete", danger: true) { deleteTrigger(at: index) }
            }

            // Gate kind picker.
            HStack(spacing: MacRoTheme.Spacing.sm) {
                Text("kind")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                kindPill(label: "img", isActive: trigger.when.gateKind == .img) {
                    update(at: index) { trig in
                        StopOnTrigger(
                            when: .init(gateKind: .img, ref: trig.when.ref),
                            action: trig.action,
                            message: trig.message
                        )
                    }
                }
                kindPill(label: "pos", isActive: trigger.when.gateKind == .pos) {
                    update(at: index) { trig in
                        StopOnTrigger(
                            when: .init(gateKind: .pos, ref: trig.when.ref),
                            action: trig.action,
                            message: trig.message
                        )
                    }
                }
            }

            // Ref string.
            HStack(spacing: MacRoTheme.Spacing.sm) {
                Text("ref")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                TextField("ref", text: Binding(
                    get: { trigger.when.ref },
                    set: { newValue in
                        update(at: index) { trig in
                            StopOnTrigger(
                                when: .init(gateKind: trig.when.gateKind, ref: newValue),
                                action: trig.action,
                                message: trig.message
                            )
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .font(MacRoTheme.Font.mono)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, MacRoTheme.Spacing.sm)
                .padding(.vertical, MacRoTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .fill(MacRoTheme.Color.bgRaised)
                )
            }

            // Action picker.
            HStack(spacing: MacRoTheme.Spacing.sm) {
                Text("action")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                kindPill(label: "pause", isActive: trigger.action == .literal(.pause)) {
                    update(at: index) { trig in
                        StopOnTrigger(when: trig.when, action: .literal(.pause), message: trig.message)
                    }
                }
                kindPill(label: "exit", isActive: trigger.action == .literal(.exit)) {
                    update(at: index) { trig in
                        StopOnTrigger(when: trig.when, action: .literal(.exit), message: trig.message)
                    }
                }
                if case .subInvocation(let name) = trigger.action {
                    Text("sub:\(name)")
                        .font(MacRoTheme.Font.mono)
                        .foregroundStyle(MacRoTheme.Color.fg2)
                }
            }

            // Message.
            HStack(spacing: MacRoTheme.Spacing.sm) {
                Text("msg")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                TextField("(optional notification message)", text: Binding(
                    get: { trigger.message ?? "" },
                    set: { newValue in
                        update(at: index) { trig in
                            StopOnTrigger(
                                when: trig.when,
                                action: trig.action,
                                message: newValue.isEmpty ? nil : newValue
                            )
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, MacRoTheme.Spacing.sm)
                .padding(.vertical, MacRoTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .fill(MacRoTheme.Color.bgRaised)
                )
            }
        }
        .padding(MacRoTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                .fill(MacRoTheme.Color.bgRaised.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .strokeBorder(MacRoTheme.Color.laneBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Mutations

    private func addTrigger() {
        var triggers = currentTriggers
        triggers.append(StopOnTrigger(
            when: .init(gateKind: .img, ref: "new-trigger"),
            action: .literal(.pause),
            message: nil
        ))
        dispatch(EditorCommands.replaceStopOn(
            with: triggers,
            label: "Add stopOn trigger",
            from: state
        ))
    }

    private func deleteTrigger(at index: Int) {
        var triggers = currentTriggers
        guard index >= 0 && index < triggers.count else { return }
        triggers.remove(at: index)
        dispatch(EditorCommands.replaceStopOn(
            with: triggers,
            label: "Delete stopOn trigger",
            from: state
        ))
    }

    private func update(at index: Int, _ transform: (StopOnTrigger) -> StopOnTrigger) {
        var triggers = currentTriggers
        guard index >= 0 && index < triggers.count else { return }
        triggers[index] = transform(triggers[index])
        dispatch(EditorCommands.replaceStopOn(
            with: triggers,
            label: "Edit stopOn trigger",
            from: state
        ))
    }

    // MARK: - Pills

    @ViewBuilder
    private func kindPill(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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

    @ViewBuilder
    private func pillButton(label: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(danger ? MacRoTheme.Color.stateDanger : MacRoTheme.Color.fg2)
                .padding(.horizontal, MacRoTheme.Spacing.sm)
                .padding(.vertical, MacRoTheme.Spacing.xs)
                .overlay(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .strokeBorder(
                            (danger ? MacRoTheme.Color.stateDanger : MacRoTheme.Color.fg3).opacity(0.4),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
