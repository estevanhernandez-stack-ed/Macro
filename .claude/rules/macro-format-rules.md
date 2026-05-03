# Macro format rules — `.macro` bundles

**STUB — expand once `schema/macro.schema.yaml` exists.**

Planned content:

- **Schema versioning rule**: bumping `schemaVersion` requires a logged decision in the 626Labs Dashboard. The engine refuses to play unknown schema versions; codegen consumers (Swift `MacroFormat`, TS factory types) must be regenerated and the spec doc must be updated in the same PR
- **`factoryPatchable: true` semantics**: opt-in only. The factory ignores `factoryPatchable: false` macros entirely. Tools that surface "patch this macro" must respect this field
- **Gate type semantics**: POS gates verify position via image-of-environment (looser similarity threshold ~85%); IMG gates verify UI state via image-of-UI (tighter ~95%). Don't mix the two semantically — a POS gate referencing a UI element image is a bug
- **Resolution policy semantics**: `scale` (proportional), `anchor-to-window` (raw window-relative — only safe at recorded resolution), `image-anchored` (recompute from gate image-search). The engine warns when running a macro at a resolution different from `target.recordedResolution`
- **Sub-macro non-recursion rule**: subs cannot directly self-invoke; indirect cycles are warnings (the engine has a runaway-loop guard but cycles waste cycles)
- **Image ref naming convention**: `gates/<gateKind>-<descriptive-slug>.png` (e.g., `gates/img-catch-prompt.png`, `gates/pos-fishing-spot.png`). Makes the `timeline.yaml` readable

Loaded by the `macro-bundle-validator` agent when checking bundle correctness.

Spec section reference: `docs/superpowers/specs/2026-05-03-macro-mac-app-design.md` § 4.
