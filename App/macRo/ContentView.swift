// ContentView.swift
// macRo — placeholder content view for the v1 shell.
//
// Renders the brand glyph (cyan/magenta gradient swoosh, abstract) and the
// "macRo" wordmark over a deep-navy field. All colors and fonts route through
// MacRoTheme — no hardcoded styling. Full surface (Library, Onboarding,
// Editor, Recorder, RunHUD) lands in later checklist items.

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            MacRoTheme.Color.bgPage
                .ignoresSafeArea()

            VStack(spacing: 24) {
                BrandGlyph()
                    .frame(width: 96, height: 96)

                Text("macRo")
                    .font(MacRoTheme.Font.display)
                    .foregroundStyle(MacRoTheme.Color.fg1)

                Text("Imagine Something Else.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .tracking(0.3)
            }
            .padding(48)
        }
    }
}

/// Placeholder brand glyph — abstract cyan→magenta gradient swoosh.
/// Real lockup lands during the first 626labs-design-skill authoring beat.
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
    ContentView()
}
