// GamePickSheet.swift
// UI — modal sheet for picking a game before recording starts.
//
// Lists each `GameSelection` case as a card (mirrors OnboardingView's
// PermissionCard pattern). Default selection is PS99 — the v1 anchor
// game; Untagged is the escape hatch for non-PS99 macros.
//
// Spec ref: docs/spec.md > Recorder ("game-pick sheet") +
// docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + docs/prd.md > Epic B (game-pick acceptance).
//
// Voice: builder-to-builder, sentence case, no emoji. All visuals via
// MacRoTheme.

import SwiftUI

/// Sheet presented before recording starts. Caller passes a
/// `onConfirm(GameSelection)` callback; we dismiss before invoking it
/// so the calling view can drive the post-pick orchestration
/// (countdown overlay → recorder start) without competing for a
/// dismissal animation.
struct GamePickSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var selection: GameSelection = .ps99

    /// Called with the chosen GameSelection AFTER the sheet dismisses.
    /// ContentView wires this to present the CountdownOverlay.
    let onConfirm: (GameSelection) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.lg) {
            header
            cards
            Spacer(minLength: 0)
            footer
        }
        .padding(MacRoTheme.Spacing.xl)
        .frame(width: 560, height: 480)
        .background(MacRoTheme.Color.bgPage)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            Text("What game?")
                .font(MacRoTheme.Font.heading1)
                .foregroundStyle(MacRoTheme.Color.fg1)
            Text("Pick the game you're recording for. The choice pre-fills the macro's window matchers and target resolution.")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cards

    private var cards: some View {
        VStack(spacing: MacRoTheme.Spacing.md) {
            GameCard(
                name: "Pet Simulator 99",
                description: "v1 anchor game. Auto-fills target window selectors and recorded resolution.",
                tag: "Default",
                isSelected: selection == .ps99,
                onTap: { selection = .ps99 }
            )
            GameCard(
                name: "Untagged / general",
                description: "For non-PS99 macros. You'll set the window selectors manually later.",
                tag: nil,
                isSelected: selection == .untagged,
                onTap: { selection = .untagged }
            )
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: MacRoTheme.Spacing.md) {
            SecondaryCTAButton(title: "Cancel") {
                dismiss()
                onCancel()
            }
            Spacer()
            PrimaryCTAButton(title: "Start Recording") {
                let chosen = selection
                dismiss()
                // Defer one runloop so the sheet's dismissal animation
                // doesn't fight the next overlay's presentation. Without
                // this, the countdown panel can race the sheet's
                // unmount and end up underneath.
                DispatchQueue.main.async {
                    onConfirm(chosen)
                }
            }
        }
    }
}

// MARK: - Per-game card

private struct GameCard: View {
    let name: String
    let description: String
    let tag: String?
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
                HStack(spacing: MacRoTheme.Spacing.sm) {
                    Text(name)
                        .font(MacRoTheme.Font.body)
                        .foregroundStyle(MacRoTheme.Color.fg1)
                    if let tag {
                        Text(tag)
                            .font(MacRoTheme.Font.monoMicro)
                            .foregroundStyle(MacRoTheme.Color.productTeal)
                            .tracking(0.12 * 11)
                            .textCase(.uppercase)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(MacRoTheme.Color.productTeal.opacity(0.16))
                            )
                    }
                    Spacer()
                    SelectionDot(isSelected: isSelected)
                }
                Text(description)
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(MacRoTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.lg, style: .continuous)
                    .fill(MacRoTheme.Color.bgRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? MacRoTheme.Color.brandCyan
                            : (hovering ? MacRoTheme.Color.fg3 : MacRoTheme.Color.bgSurface),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SelectionDot: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? MacRoTheme.Color.brandCyan : MacRoTheme.Color.fg3,
                    lineWidth: 2
                )
                .frame(width: 18, height: 18)
            if isSelected {
                Circle()
                    .fill(MacRoTheme.Color.brandCyan)
                    .frame(width: 10, height: 10)
            }
        }
    }
}

// MARK: - CTAs

/// Primary CTA. Replicates OnboardingView's PrimaryButton inline because
/// that file's button is fileprivate; the consistent spec is "teal fill,
/// bgPage text, 10pt radius, contentShape rect for hit-test".
private struct PrimaryCTAButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.bgPage)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MacRoTheme.Color.productTeal.opacity(hovering ? 0.92 : 1.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SecondaryCTAButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            hovering
                                ? MacRoTheme.Color.brandCyan
                                : MacRoTheme.Color.fg3,
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

#Preview {
    GamePickSheet(
        onConfirm: { _ in },
        onCancel: {}
    )
}
