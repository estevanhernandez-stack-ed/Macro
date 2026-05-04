// OnboardingView.swift
// UI — first-launch entitlements wizard.
//
// Two steps:
//   1. Welcome — brand glyph + wordmark + tagline + one-line "what this
//      is" + Continue.
//   2. Entitlements — per-permission cards (Accessibility, Screen
//      Recording) with status indicator + action button. Continue is
//      disabled until both permissions are granted.
//
// App.swift mounts this view conditionally when `permissions.allGranted`
// is false. When the user revokes either permission in System Settings,
// the foreground-observer in `Permissions` flips `allGranted` back, and
// the WindowGroup body switches the wizard back in.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + docs/spec.md > OnboardingView + docs/prd.md > Epic A.
//
// Voice: builder-to-builder, second person, sentence case, em-dashes
// welcome, no emoji. All colors + fonts route through MacRoTheme.

import SwiftUI

/// First-launch wizard. Welcome → entitlements → app proper.
struct OnboardingView: View {

    // MARK: - Step state

    private enum Step: Hashable {
        case welcome
        case entitlements
    }

    @Environment(Permissions.self) private var permissions
    @State private var step: Step = .welcome

    var body: some View {
        ZStack {
            MacRoTheme.Color.bgPage.ignoresSafeArea()

            switch step {
            case .welcome:
                WelcomeStep(onContinue: { step = .entitlements })
            case .entitlements:
                EntitlementsStep()
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear { permissions.refresh() }
    }
}

// MARK: - Welcome step

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            BrandGlyph()
                .frame(width: 96, height: 96)

            VStack(spacing: 8) {
                Text("macRo")
                    .font(MacRoTheme.Font.display)
                    .foregroundStyle(MacRoTheme.Color.fg1)

                Text("Imagine Something Else.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .tracking(0.3)
            }

            Text("Record gameplay, edit on a timeline, replay your macros.")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            Spacer(minLength: 0)

            PrimaryButton(title: "Continue", action: onContinue)

            Spacer(minLength: 0)
        }
        .padding(48)
    }
}

// MARK: - Entitlements step

private struct EntitlementsStep: View {
    @Environment(Permissions.self) private var permissions

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Two permissions, then you're in")
                    .font(MacRoTheme.Font.heading1)
                    .foregroundStyle(MacRoTheme.Color.fg1)

                Text("macRo needs Accessibility to record + replay your inputs and Screen Recording to capture the Roblox window.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            .padding(.top, 24)

            VStack(spacing: 16) {
                PermissionCard(
                    name: "Accessibility",
                    reason: "macRo records what you press and click in Roblox, then plays it back. macOS treats input recording and synthesis as accessibility features.",
                    granted: permissions.accessibilityGranted,
                    primaryActionTitle: permissions.accessibilityGranted
                        ? "Open Settings"
                        : "Grant Accessibility",
                    primaryAction: {
                        if permissions.accessibilityGranted {
                            permissions.openSystemSettingsAccessibility()
                        } else {
                            permissions.requestAccessibility()
                        }
                    }
                )
                PermissionCard(
                    name: "Screen Recording",
                    reason: "macRo captures the Roblox window so the timeline editor can scrub through your gameplay frame-by-frame and add image-trigger gates.",
                    granted: permissions.screenRecordingGranted,
                    primaryActionTitle: permissions.screenRecordingGranted
                        ? "Open Settings"
                        : "Grant Screen Recording",
                    primaryAction: {
                        if permissions.screenRecordingGranted {
                            permissions.openSystemSettingsScreenRecording()
                        } else {
                            permissions.requestScreenRecording()
                        }
                    }
                )
            }
            .frame(maxWidth: 560)

            Text("After you flip a toggle in Settings, switch back to macRo — we re-check on focus.")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg3)

            Spacer(minLength: 0)

            PrimaryButton(
                title: permissions.allGranted ? "Continue to library" : "Waiting on grants",
                action: { /* gated by enabled */ }
            )
            .disabled(!permissions.allGranted)
            .opacity(permissions.allGranted ? 1.0 : 0.55)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 24)
    }
}

// MARK: - Per-permission card

private struct PermissionCard: View {
    let name: String
    let reason: String
    let granted: Bool
    let primaryActionTitle: String
    let primaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(name)
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)

                Spacer()

                StatusPill(granted: granted)
            }

            Text(reason)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                SecondaryButton(title: primaryActionTitle, action: primaryAction)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MacRoTheme.Color.bgRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MacRoTheme.Color.bgSurface, lineWidth: 1)
        )
    }
}

private struct StatusPill: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? MacRoTheme.Color.productTeal : MacRoTheme.Color.fg3)
                .frame(width: 8, height: 8)
            Text(granted ? "Granted" : "Not granted")
                .font(MacRoTheme.Font.monoMicro)
                .foregroundStyle(granted ? MacRoTheme.Color.productTeal : MacRoTheme.Color.fg3)
                .textCase(.uppercase)
                .tracking(0.12 * 11)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(MacRoTheme.Color.bgSurface)
        )
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
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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

// MARK: - Brand glyph

/// Same shape as ContentView's BrandGlyph; duplicated locally so the
/// onboarding view does not depend on Content. The real lockup lands at
/// the first 626labs-design-skill authoring beat.
private struct BrandGlyph: View {
    var body: some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    colors: [MacRoTheme.Color.brandCyan, MacRoTheme.Color.brandMagenta],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 4
            )
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                MacRoTheme.Color.brandCyan.opacity(0.18),
                                MacRoTheme.Color.brandMagenta.opacity(0.10),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
            )
    }
}

#Preview {
    OnboardingView()
        .environment(Permissions())
}
