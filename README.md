# macRo

> The Mac macro maker for Roblox. Imagine something else.

macRo records gameplay and ships diff-able macros — recorded, edited, and played from a native Mac app. Built around an iMovie-flavored authoring surface, a YAML + image-gates bundle format, and a factory pipeline that patches macros within hours of game updates.

**Status:** v1 design locked. Implementation pending.

- **Design spec:** [docs/superpowers/specs/2026-05-03-macro-mac-app-design.md](docs/superpowers/specs/2026-05-03-macro-mac-app-design.md)
- **First game:** Pet Simulator 99
- **Stack:** Swift / SwiftUI (Mac app), TS / Bun (factory pipeline, later)
- **Distribution:** Apple Developer ID signed + notarized DMG via GitHub Releases. Sparkle 2.x for auto-update.
- **Telemetry:** None. Anonymous GitHub release download counts only.

A 626 Labs project.
