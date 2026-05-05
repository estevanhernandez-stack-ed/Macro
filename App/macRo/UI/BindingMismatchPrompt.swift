// BindingMismatchPrompt.swift
// UI — pre-flight binding-confirmation modal.
//
// Engine pre-flight (spec § 6 step 3) calls `pendingBindingsCheck` with
// the active manifest. macRo can't tell from the outside whether the
// user actually has these keys bound in Roblox — Carbon's
// `CopySymbolicHotKeys` only sees system shortcuts, not in-game key
// bindings. The honest move in 5b is to show the user what the macro
// expects and let them confirm.
//
// "Remember for this macro" persists the user's confirmation in
// UserDefaults under `macRo.bindings.<manifest.id>`. When the value is
// `true`, the engine's wired callback short-circuits and never presents
// this modal for that macro again. Toggling Remember + clicking Cancel
// does NOT persist — Cancel means "don't trust this state at all."
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + docs/spec.md > Engine + docs/prd.md > Epic D.
//
// Voice: builder-to-builder, second person, sentence case, em-dashes
// welcome, no emoji. All visuals route through MacRoTheme.

import SwiftUI

// MARK: - Defaults helper

/// UserDefaults key namespace for per-macro "remember confirmation"
/// flags. Public so the engine's wired callback can read it without
/// duplicating the key format.
public enum BindingMismatchDefaults {
    /// Returns the UserDefaults key for a given macro id. Format:
    /// `macRo.bindings.<id>`. The id comes straight from
    /// `manifest.id` (slug-form already; no escaping needed).
    public static func key(for manifestID: String) -> String {
        return "macRo.bindings.\(manifestID)"
    }

    /// Read-side of the contract. Returns true if the user has already
    /// said "remember" for this macro.
    public static func isRemembered(_ manifestID: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: manifestID))
    }

    /// Write-side. Only called from the modal when the user clicks
    /// Continue with Remember toggled on.
    public static func setRemembered(_ manifestID: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key(for: manifestID))
    }
}

// MARK: - View

/// Modal sheet shown when the engine's pre-flight asks the user to
/// confirm a macro's required bindings. Drives a single Bool resolution
/// callback — the engine awaits this Bool before transitioning past
/// pre-flight step 3.
public struct BindingMismatchPrompt: View {

    // MARK: Inputs

    /// The manifest whose `requires.bindings` we're surfacing. Read-only.
    public let manifest: Manifest

    /// Resolution callback. `true` = continue (engine proceeds);
    /// `false` = cancel (engine aborts pre-flight with
    /// `EngineError.bindingsNotConfirmed`). Called exactly once.
    public let onResolve: (Bool) -> Void

    // MARK: State

    @State private var rememberChoice: Bool = false

    // MARK: Init

    public init(
        manifest: Manifest,
        onResolve: @escaping (Bool) -> Void
    ) {
        self.manifest = manifest
        self.onResolve = onResolve
    }

    // MARK: Body

    public var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.lg) {
            header
            bindingsList
            Spacer(minLength: 0)
            footer
        }
        .padding(MacRoTheme.Spacing.xl)
        .frame(minWidth: 480, minHeight: 360)
        .background(MacRoTheme.Color.bgPage)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            Text("Confirm your bindings")
                .font(MacRoTheme.Font.heading1)
                .foregroundStyle(MacRoTheme.Color.fg1)

            Text("This macro expects the keys below to be bound in \(gameDisplayName). macRo can't read in-game bindings — verify they're set, then continue.")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var bindingsList: some View {
        let items = manifest.requires?.bindings ?? []
        if items.isEmpty {
            // Defensive: pre-flight shouldn't even invoke this modal
            // when the manifest has no bindings, but if it does, render
            // an honest empty state rather than a wall of nothing.
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("This macro doesn't declare any required bindings.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg2)
            }
            .padding(MacRoTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                    .fill(MacRoTheme.Color.bgSurface)
            )
        } else {
            VStack(spacing: MacRoTheme.Spacing.sm) {
                ForEach(items, id: \.action) { item in
                    BindingRow(action: item.action, expected: item.expected)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            RememberToggle(isOn: $rememberChoice)

            HStack(spacing: MacRoTheme.Spacing.md) {
                Spacer()
                SecondaryButton(title: "Cancel") {
                    // Cancel never persists Remember — toggling it on then
                    // backing out is "I changed my mind," not "trust this."
                    onResolve(false)
                }
                PrimaryButton(title: "Continue anyway") {
                    if rememberChoice {
                        BindingMismatchDefaults.setRemembered(manifest.id, true)
                    }
                    onResolve(true)
                }
            }
        }
    }

    // MARK: Helpers

    private var gameDisplayName: String {
        manifest.game?.name ?? "Roblox"
    }
}

// MARK: - Per-binding row

private struct BindingRow: View {
    let action: String
    let expected: String

    var body: some View {
        HStack(spacing: MacRoTheme.Spacing.md) {
            // Status indicator. We can't actually verify the binding —
            // the row stays in "needs your eyes" warning until the user
            // confirms the whole modal. Honest > misleading green check.
            StatusDot(state: .pending)

            VStack(alignment: .leading, spacing: 2) {
                Text(action)
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text("Expected key — check your in-game settings.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }

            Spacer()

            // Expected key chip — JetBrains Mono, uppercase, tracked.
            Text(expected.uppercased())
                .font(MacRoTheme.Font.mono)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .tracking(0.12 * 13)
                .padding(.horizontal, MacRoTheme.Spacing.md)
                .padding(.vertical, MacRoTheme.Spacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                        .fill(MacRoTheme.Color.bgRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                        .strokeBorder(MacRoTheme.Color.bgSurface, lineWidth: 1)
                )
        }
        .padding(MacRoTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                .fill(MacRoTheme.Color.bgSurface)
        )
    }
}

// MARK: - Status dot

private enum BindingStatus {
    case ok       // green check (reserved — wired when binding query lands)
    case pending  // amber warn (current default, "needs your eyes")
    case missing  // red X (reserved — wired when binding query lands)
}

private struct StatusDot: View {
    let state: BindingStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .strokeBorder(color.opacity(0.5), lineWidth: 1)
                    .frame(width: 14, height: 14)
            )
    }

    private var color: SwiftUI.Color {
        switch state {
        case .ok:      return MacRoTheme.Color.stateOk
        case .pending: return MacRoTheme.Color.stateWarn
        case .missing: return MacRoTheme.Color.stateDanger
        }
    }
}

// MARK: - Remember toggle

private struct RememberToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember for this macro")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text("Don't ask again on the next run.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }
        }
        .toggleStyle(.switch)
        .tint(MacRoTheme.Color.productTeal)
    }
}

// MARK: - Buttons

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.bgPage)
                .padding(.horizontal, MacRoTheme.Spacing.lg)
                .padding(.vertical, MacRoTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                        .fill(MacRoTheme.Color.productTeal.opacity(hovering ? 0.92 : 1.0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, MacRoTheme.Spacing.lg)
                .padding(.vertical, MacRoTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                        .strokeBorder(
                            hovering
                                ? MacRoTheme.Color.brandCyan
                                : MacRoTheme.Color.fg3,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

#Preview {
    let manifest = Manifest(
        id: "ps99-auto-hatch-v1",
        name: "Auto Hatch",
        version: "1.0.0",
        schemaVersion: 1,
        factoryPatchable: true,
        game: GameTag(name: "Pet Simulator 99"),
        requires: Requires(bindings: [
            .init(action: "Interact", expected: "E"),
            .init(action: "Open menu", expected: "Tab")
        ])
    )
    return BindingMismatchPrompt(manifest: manifest, onResolve: { _ in })
}
