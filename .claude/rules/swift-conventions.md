# Swift conventions — macRo

**STUB — expand once Swift code begins to land.**

Planned content:

- **Threading discipline** (the four-thread rule from spec Section 3): capture/encoding on SCK queue, input event tap on dedicated thread, engine playback on serial queue, UI on main only
- **Layered dependency direction**: native services → domain → UI; never reverse
- **`MacroFormat` module isolation**: schema types module has zero dependencies; both domain and UI reach through its public API
- **`MacRoTheme` indirection**: no hardcoded colors / fonts / spacing in views
- **Apple API idioms**: ScreenCaptureKit (modern, not deprecated CGDisplayStream), CGEventTap (allocate, enable, disable, invalidate), CGEvent.post (`.cghidEventTap` + screen-space coords), AVAssetWriter for encoding, AXUIElement for window detection
- **SwiftUI patterns**: views in their own files, `@Observable` over `ObservableObject` (Swift 5.9+), `Task` not `DispatchQueue.global` for async, structured concurrency for the engine's playback loop where it doesn't conflict with the dedicated-queue requirement

Loaded by the `swift-mac-app-reviewer` agent when reviewing changed Swift code.
