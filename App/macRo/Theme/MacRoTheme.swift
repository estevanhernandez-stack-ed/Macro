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

        // Editor lane palette (item 8a).
        //
        // Lanes need to read at a glance even when the timeline is dense —
        // a 500-event recording lays out as a wall of bars. The palette
        // honors the v2 mockup mapping (kept = blue, cut = gray, MOVE keys
        // = green, camera = blue accent) but pulls all values from the
        // brand surfaces so the editor stays inside the deep-navy field
        // rather than turning into iMovie-grey. Spec § 8 calls these
        // "VIDEO blue / MOVE cyan / camera magenta / ACTIONS white" —
        // we choose softer values for non-active states so the eye lands
        // on the playhead, not the lane chrome.
        static let laneBg          = bgRaised                         // lane track background
        static let laneBorder      = SwiftUI.Color(hex: 0x2D4866)     // hairline between lanes
        static let videoKept       = SwiftUI.Color(hex: 0x4A90E2)     // blue kept-segment
        static let videoCut        = SwiftUI.Color(hex: 0x3A4A5E)     // muted gray cut-segment
        static let moveKey         = SwiftUI.Color(hex: 0x6AB04C)     // held-key bar (WASD)
        static let moveCamera      = SwiftUI.Color(hex: 0x4A8CAF)     // camera-delta bar
        static let actionDot       = fg1                              // click marker
        static let actionGlyphBg   = SwiftUI.Color(hex: 0x4F5C6F)     // key-press glyph chip
        static let scrubCursor     = brandMagenta                     // playhead line — magenta cuts through everything
        static let scrubCursorGlow = brandMagenta.opacity(0.32)

        // GATES lane (item 8b).
        //
        // POS gates are MAGENTA outline diamonds (looser ~85% threshold —
        // image-of-environment, "is the scene right?"). IMG gates are CYAN
        // filled diamonds (tighter ~95% — image-of-UI, "is the prompt up?").
        // Both pull from the brand duotone so the lane reads as part of the
        // 626Labs surface, not iMovie chrome.
        //
        // Selection ring uses productTeal so it stays out of the brand
        // duotone (selection is a UI state, not a brand surface — mixing
        // them dilutes both signals; carry-over rule from RunHUD's status
        // pill treatment).
        static let gateSelectionRing = productTeal

        // Editable VIDEO lane (item 8b) — active drag handle at cut
        // boundaries. The 8a CutHandle was visible-but-disabled at fg1 60%
        // opacity; the editable version reads as "grabbable" via teal +
        // hairline border. Different token so the read-only path
        // (script-view item 8c) keeps the disabled visual.
        static let videoHandle     = productTeal

        // Inspector panel (item 8b) — slightly raised against bgPage so
        // the right-side panel reads as a separate surface even on small
        // editor windows. We reuse bgSurface rather than introducing a
        // distinct color so the editor stays inside the deep-navy field;
        // the panel feels structural, not floating.
        static let inspectorBg     = bgSurface
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

    // MARK: - Lane geometry (item 8a — editor)

    /// Editor lane geometry. Heights chosen so a four-lane stack reads
    /// without scrolling on a 13" laptop while leaving the video preview
    /// breathing room above. The label gutter is wide enough for
    /// "ACTIONS" + "GATES" in JetBrains Mono micro without truncation.
    /// Bumping these is a load-bearing visual decision — the v2 mockup
    /// is locked, so changes here should reference a follow-up
    /// brainstorm artifact.
    enum Lane {
        /// Vertical spacing between each lane row.
        static let rowGap: CGFloat = 8
        /// Width of the left-edge label column ("VIDEO", "MOVE", …).
        static let labelGutter: CGFloat = 88
        /// VIDEO lane track height. Slightly taller than MOVE/ACTIONS
        /// because the kept/cut segments need to read as the spine of
        /// the timeline.
        static let videoHeight: CGFloat = 36
        /// MOVE lane track height — held-key bars need vertical room
        /// for a key glyph + duration string.
        static let moveHeight: CGFloat = 30
        /// ACTIONS lane height — dots + boxed glyphs sit short.
        static let actionsHeight: CGFloat = 26
        /// GATES lane placeholder height (item 8b populates).
        static let gatesHeight: CGFloat = 26
        /// Minimum width for a held-key bar so a 50ms tap stays
        /// hit-testable + visible. Smaller bars get clamped up.
        static let minBarWidth: CGFloat = 4
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
