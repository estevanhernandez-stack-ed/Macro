// SubsPanel.swift
// UI — toolbar sheet for managing named sub-macros (item 8c).
//
// Sub-macros are the engine's named helper bodies; `invokeSub` events
// + `stopOn` actions of the form `sub:<name>` reach them. The panel
// shows the list of names from `WorkingState.bundle.timeline.subs`
// and lets the user:
//
//   - Add a new (empty) sub by name
//   - Rename an existing sub
//   - Delete a sub
//
// Editing the sub's BODY (its inner timeline events) defers to
// /iterate — a full nested-timeline editor inside the panel is a
// larger surface than 8c can absorb. For now the panel surfaces a
// read-only event count + a "edit body in script view" hint so the
// user knows where to author the inner events. The script view
// (EditorScriptView) does round-trip the full subs body losslessly,
// so power users can edit there until the inline editor lands.
//
// All mutations route through `dispatch(EditorCommands.replaceSubs)`
// so undo/redo covers them. Visual treatment via MacRoTheme.

import SwiftUI

struct SubsPanel: View {

    let state: WorkingState
    let dispatch: (EditorCommand) -> Void
    let onClose: () -> Void

    /// Inline edit drafts. Empty string ↔ no draft.
    @State private var newSubName: String = ""
    @State private var renameTarget: String? = nil
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            header

            Divider().background(MacRoTheme.Color.laneBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
                    if currentSubs.isEmpty {
                        emptyState
                    } else {
                        ForEach(sortedSubNames, id: \.self) { name in
                            row(name: name, sub: currentSubs[name]!)
                        }
                    }
                }
                .padding(MacRoTheme.Spacing.md)
            }
            .background(MacRoTheme.Color.bgPage)
            .clipShape(RoundedRectangle(cornerRadius: MacRoTheme.Radius.md))

            Divider().background(MacRoTheme.Color.laneBorder)

            addRow

            Divider().background(MacRoTheme.Color.laneBorder)

            footer
        }
        .padding(MacRoTheme.Spacing.lg)
        .frame(width: 540, height: 480)
        .background(MacRoTheme.Color.bgSurface)
    }

    // MARK: - Computed

    private var currentSubs: [String: SubMacro] {
        state.bundle.timeline.subs ?? [:]
    }

    private var sortedSubNames: [String] {
        currentSubs.keys.sorted()
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("SUBS")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("·")
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("named sub-macros (\(currentSubs.count))")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
            Spacer()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            Text("No subs yet")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg2)
            Text("Subs are named helper bodies invoked from the timeline (via invokeSub events) or from stopOn actions of the form sub:<name>. Add one below; edit its events from the script view.")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg3)
        }
    }

    @ViewBuilder
    private func row(name: String, sub: SubMacro) -> some View {
        HStack(spacing: MacRoTheme.Spacing.sm) {
            if renameTarget == name {
                TextField("name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                    .padding(.horizontal, MacRoTheme.Spacing.sm)
                    .padding(.vertical, MacRoTheme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                            .fill(MacRoTheme.Color.bgPage)
                    )
                    .onSubmit { commitRename(from: name) }

                pillButton(label: "Save") { commitRename(from: name) }
                pillButton(label: "Cancel") {
                    renameTarget = nil
                    renameDraft = ""
                }
            } else {
                Text(name)
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Spacer()
                Text("\(sub.events.count) event\(sub.events.count == 1 ? "" : "s")")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                pillButton(label: "Rename") {
                    renameTarget = name
                    renameDraft = name
                }
                pillButton(label: "Delete", danger: true) { deleteSub(named: name) }
            }
        }
        .padding(.horizontal, MacRoTheme.Spacing.sm)
        .padding(.vertical, MacRoTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                .fill(MacRoTheme.Color.bgRaised)
        )
    }

    @ViewBuilder
    private var addRow: some View {
        HStack(spacing: MacRoTheme.Spacing.sm) {
            TextField("new-sub-name", text: $newSubName)
                .textFieldStyle(.plain)
                .font(MacRoTheme.Font.mono)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, MacRoTheme.Spacing.sm)
                .padding(.vertical, MacRoTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .fill(MacRoTheme.Color.bgPage)
                )
                .onSubmit(addSub)

            pillButton(label: "+ Add sub") { addSub() }
                .disabled(newSubName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text("Edit a sub's body in the script view (toolbar `{ } script`).")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
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

    // MARK: - Mutations

    private func addSub() {
        let trimmed = newSubName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var subs = currentSubs
        guard subs[trimmed] == nil else { return } // duplicate — silent no-op
        subs[trimmed] = SubMacro(events: [])
        dispatch(EditorCommands.replaceSubs(
            with: subs,
            label: "Add sub \"\(trimmed)\"",
            from: state
        ))
        newSubName = ""
    }

    private func commitRename(from oldName: String) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        defer {
            renameTarget = nil
            renameDraft = ""
        }
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        var subs = currentSubs
        guard let body = subs[oldName], subs[trimmed] == nil else { return }
        subs.removeValue(forKey: oldName)
        subs[trimmed] = body
        dispatch(EditorCommands.replaceSubs(
            with: subs,
            label: "Rename sub \"\(oldName)\" → \"\(trimmed)\"",
            from: state
        ))
    }

    private func deleteSub(named name: String) {
        var subs = currentSubs
        guard subs[name] != nil else { return }
        subs.removeValue(forKey: name)
        dispatch(EditorCommands.replaceSubs(
            with: subs,
            label: "Delete sub \"\(name)\"",
            from: state
        ))
    }

    // MARK: - Pill button

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
