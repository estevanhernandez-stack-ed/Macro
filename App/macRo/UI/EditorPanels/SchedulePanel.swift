// SchedulePanel.swift
// UI — toolbar sheet for managing manifest.schedule[] windows (item 8c).
//
// Schedule windows constrain WHEN the engine is allowed to run.
// Pre-flight checks the user's current time against every window;
// if no window matches, the run aborts with a "out of schedule"
// message (spec § 6).
//
// Each window has:
//   - between: { from: HH:MM, to: HH:MM, timezone: "local" or IANA }
//
// The schema only carries `between` today (no `days[]` field exists
// on `ScheduleWindow` in MacroFormat.swift). Adding `days` is a
// schema bump + logged decision — defer to /iterate. For 8c we edit
// from / to / timezone only; "Mon-Fri" type windows are out of
// scope for v1.
//
// All mutations route through `dispatch(EditorCommands.replaceSchedule)`
// so undo/redo covers them. Visual treatment via MacRoTheme.

import SwiftUI

struct SchedulePanel: View {

    let state: WorkingState
    let dispatch: (EditorCommand) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            header

            Divider().background(MacRoTheme.Color.laneBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
                    if currentWindows.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(currentWindows.enumerated()), id: \.offset) { idx, win in
                            row(index: idx, window: win)
                        }
                    }
                }
                .padding(MacRoTheme.Spacing.md)
            }
            .background(MacRoTheme.Color.bgPage)
            .clipShape(RoundedRectangle(cornerRadius: MacRoTheme.Radius.md))

            Divider().background(MacRoTheme.Color.laneBorder)

            HStack {
                pillButton(label: "+ Add window", action: addWindow)
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
        .frame(width: 540, height: 460)
        .background(MacRoTheme.Color.bgSurface)
    }

    // MARK: - Computed

    private var currentWindows: [ScheduleWindow] {
        state.bundle.manifest.schedule ?? []
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("SCHEDULE")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("·")
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("time windows (\(currentWindows.count)) — engine refuses to run outside")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
            Spacer()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            Text("No schedule windows")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg2)
            Text("Without windows the engine runs whenever invoked. Add a window (e.g., 22:00 → 06:00) to constrain runs to off-hours.")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg3)
        }
    }

    @ViewBuilder
    private func row(index: Int, window: ScheduleWindow) -> some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            HStack {
                Text("#\(index + 1)")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                Spacer()
                pillButton(label: "Delete", danger: true) { deleteWindow(at: index) }
            }

            HStack(spacing: MacRoTheme.Spacing.sm) {
                Text("from")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                hhmmField(value: window.between.from) { newValue in
                    update(at: index) { win in
                        ScheduleWindow(between: .init(
                            from: newValue,
                            to: win.between.to,
                            timezone: win.between.timezone
                        ))
                    }
                }
                Text("to")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                hhmmField(value: window.between.to) { newValue in
                    update(at: index) { win in
                        ScheduleWindow(between: .init(
                            from: win.between.from,
                            to: newValue,
                            timezone: win.between.timezone
                        ))
                    }
                }
            }

            HStack(spacing: MacRoTheme.Spacing.sm) {
                Text("tz")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                TextField("local", text: Binding(
                    get: { window.between.timezone ?? "local" },
                    set: { newValue in
                        update(at: index) { win in
                            ScheduleWindow(between: .init(
                                from: win.between.from,
                                to: win.between.to,
                                timezone: newValue.isEmpty ? nil : newValue
                            ))
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
                Text("local or IANA name (e.g., America/Chicago)")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
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

    @ViewBuilder
    private func hhmmField(value: String, onChange: @escaping (String) -> Void) -> some View {
        TextField("HH:MM", text: Binding(get: { value }, set: { onChange($0) }))
            .textFieldStyle(.plain)
            .font(MacRoTheme.Font.mono)
            .foregroundStyle(MacRoTheme.Color.fg1)
            .frame(width: 70)
            .padding(.horizontal, MacRoTheme.Spacing.sm)
            .padding(.vertical, MacRoTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                    .fill(MacRoTheme.Color.bgRaised)
            )
    }

    // MARK: - Mutations

    private func addWindow() {
        var windows = currentWindows
        windows.append(ScheduleWindow(between: .init(
            from: "00:00",
            to: "06:00",
            timezone: "local"
        )))
        dispatch(EditorCommands.replaceSchedule(
            with: windows,
            label: "Add schedule window",
            from: state
        ))
    }

    private func deleteWindow(at index: Int) {
        var windows = currentWindows
        guard index >= 0 && index < windows.count else { return }
        windows.remove(at: index)
        dispatch(EditorCommands.replaceSchedule(
            with: windows,
            label: "Delete schedule window",
            from: state
        ))
    }

    private func update(at index: Int, _ transform: (ScheduleWindow) -> ScheduleWindow) {
        var windows = currentWindows
        guard index >= 0 && index < windows.count else { return }
        windows[index] = transform(windows[index])
        dispatch(EditorCommands.replaceSchedule(
            with: windows,
            label: "Edit schedule window",
            from: state
        ))
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
