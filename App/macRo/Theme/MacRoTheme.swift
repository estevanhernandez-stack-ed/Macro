// MacRoTheme.swift
// 626Labs design tokens, mapped to SwiftUI types.
//
// FULL MAPPING TBD via 626labs-design skill at first real SwiftUI authoring beat.
// This stub carries only the load-bearing brand colors, the deep-navy field, and
// the three font families. Spacing, radii, glow / elevation, semantic state colors,
// and the type scale all land at the first real screen authoring beat — invoke
// the `626labs-design` skill then so the mapping reflects canonical tokens, not
// memory.
//
// Token source of truth: ~/projects/626labs-design/colors_and_type.css
// Skill: ~/.claude/skills/626labs-design/

import SwiftUI

enum MacRoTheme {

    // MARK: - Color

    enum Color {
        // Brand — paired duotone (cyan + magenta) per design spec § 8.
        static let brandCyan    = SwiftUI.Color(hex: 0x17D4FA) // --brand-cyan
        static let brandMagenta = SwiftUI.Color(hex: 0xF22F89) // --brand-magenta

        // Product-specific — teal CTA accent (matches The Lab Dashboard treatment).
        static let productTeal  = SwiftUI.Color(hex: 0x2EE6C9)

        // Surface field — deep navy pair from the brand system.
        static let bgPage       = SwiftUI.Color(hex: 0x091023) // brand-navy-deep-est (page / "void")
        static let bgSurface    = SwiftUI.Color(hex: 0x192E44) // --brand-navy
        static let bgRaised     = SwiftUI.Color(hex: 0x223A54) // --brand-navy-soft

        // Foreground — primary / secondary text on dark.
        static let fg1          = SwiftUI.Color(hex: 0xFFFFFF) // --fg-1
        static let fg2          = SwiftUI.Color(hex: 0xC4CDDA) // --fg-2 (--ink-200)
        static let fg3          = SwiftUI.Color(hex: 0x8E9BAD) // --fg-3 (--ink-300)
    }

    // MARK: - Font

    enum Font {
        // Display — Space Grotesk. Falls back to the system display font when the
        // family isn't installed; the bundled-font installation lands at the first
        // real authoring beat.
        static let display     = SwiftUI.Font.custom("Space Grotesk", size: 40, relativeTo: .largeTitle)
            .weight(.bold)

        static let heading1    = SwiftUI.Font.custom("Space Grotesk", size: 32, relativeTo: .title)
            .weight(.bold)

        // Body — Inter for UI prose.
        static let body        = SwiftUI.Font.custom("Inter", size: 16, relativeTo: .body)
        static let bodySmall   = SwiftUI.Font.custom("Inter", size: 14, relativeTo: .callout)

        // Code / meta — JetBrains Mono. Use uppercase + 0.12em tracking on small
        // labels per design spec § 8.
        static let mono        = SwiftUI.Font.custom("JetBrains Mono", size: 13, relativeTo: .caption)
        static let monoMicro   = SwiftUI.Font.custom("JetBrains Mono", size: 11, relativeTo: .caption2)
            .weight(.semibold)
    }
}

// MARK: - Hex helper

private extension SwiftUI.Color {
    /// Initialize a Color from a 0xRRGGBB integer literal. v1 stub — full Color
    /// extension (with alpha + opacity helpers) lands at the first real authoring
    /// beat alongside the design-skill mapping.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
