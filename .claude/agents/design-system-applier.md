---
name: design-system-applier
description: Reviews UI changes for adherence to the 626Labs design system as applied through `MacRoTheme`. Flags hardcoded colors, hardcoded fonts, default SwiftUI styles, and tokens that don't reach through the theme indirection. Pairs with the `626labs-design` skill for canonical token reference.
tools: Read, Glob, Grep
model: sonnet
---

**STUB — to be expanded once `MacRoTheme` (Swift) exists and we have actual UI code to review.**

Future scope:
- Verify every color, font, spacing, and radius reaches through `MacRoTheme`
- Catch `.foregroundColor(.blue)` / `Color(red: ...)` / `.font(.body)` patterns that bypass the theme
- Cross-check against `~/projects/626labs-design/colors_and_type.css` for token names that should exist
- Reference Sanduhr für Claude as the SwiftUI 626Labs precedent
- Flag UI text that violates voice rules (corporate speak, emoji, missing periods on microcopy)

Until UI code exists, this agent has nothing to do. Re-read this stub when implementing the first SwiftUI views.
