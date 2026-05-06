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

        // Semantic state — pulled from 626labs-design `colors_and_type.css`
        // (--success / --warning / --danger / --info). Added at 5b for the
        // RunHUD state pill + BindingMismatchPrompt status indicators.
        // Do not pair with brand cyan/magenta — these are state signals, not
        // brand surfaces; mixing dilutes both.
        static let stateOk      = SwiftUI.Color(hex: 0x2BD99A) // --success
        static let stateWarn    = SwiftUI.Color(hex: 0xFFB454) // --warning
        static let stateDanger  = SwiftUI.Color(hex: 0xFF5472) // --danger
        static let stateInfo    = brandCyan                    // --info aliases brand-cyan

        // RunHUD overlay surface — slightly more opaque than bgPage so the
        // floating window reads as a panel against arbitrary backdrops
        // (Roblox, the Mac desktop, the editor). Layered as a fill + cyan
        // hairline border to honor the "always paired" duotone treatment.
        static let hudSurface   = bgSurface
        static let hudBorder    = brandCyan

        // Recording-red — RecorderHUD's pulsing dot + RECORDING pill border.
        // Brand magenta is too saturated to read as "live capture happening
        // right now"; the design system carries no "record red" token of its
        // own, so this is a one-off accent scoped to recording surfaces.
        // Hex matches the canonical broadcast-red used in QuickTime and the
        // VLC record button — sits between brand-magenta and stateDanger so
        // it doesn't collide with either signal.
        static let recordingRed = SwiftUI.Color(hex: 0xFF3B30)
    }

    // MARK: - Spacing

    /// 4-pt grid. Floating overlays (RunHUD, future RecorderHUD) lean on
    /// `xs / sm / md` for tight density; full-screen views (Onboarding,
    /// Library) use `lg / xl` for breathing room.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 32
        // Reserved for hero surfaces — countdown numerals, splash hero blocks.
        // Added at item 7b for CountdownOverlay's centered layout.
        static let xxl: CGFloat = 56
    }

    // MARK: - Radius

    /// Continuous-corner radii. Cards use `md`; pills + status capsules
    /// use `pill` (which is just "very large — let SwiftUI clamp to half
    /// the height"). HUD frame uses `lg` for a slightly chunkier silhouette.
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let pill: CGFloat = 999
    }

    // MARK: - Font

    enum Font {
        // Display — Space Grotesk. Falls back to the system display font when the
        // family isn't installed; the bundled-font installation lands at the first
        // real authoring beat.
        static let display     = SwiftUI.Font.custom("Space Grotesk", size: 40, relativeTo: .largeTitle)
            .weight(.bold)

        // Display XL — countdown numerals on CountdownOverlay (item 7b).
        // The 3-2-1 sequence needs to read instantly from across the room
        // while the user is mid-action repositioning Roblox; 160pt is the
        // smallest size that lands. Uses the same Space Grotesk family so
        // it inherits the brand's display voice.
        static let displayXL   = SwiftUI.Font.custom("Space Grotesk", size: 160, relativeTo: .largeTitle)
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
