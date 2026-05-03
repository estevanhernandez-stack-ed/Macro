# Release process — macRo

**STUB — expand once Xcode project exists and the first release approaches.**

Planned content:

- **Notarize-in-CI**: `tools/release/notarize.sh` runs in GitHub Actions on `v*` tag push. Apple Developer ID credentials live in GitHub-hosted secrets, not on any laptop. Build, sign, notarize, staple, attach DMG to GitHub Release.
- **Sparkle EdDSA key handling**: private key generated at first release, stored in 1Password under `macRo / Sparkle Private Key`. Public key checked into the app bundle. Recovery flow: regenerate is a one-way break (every existing client refuses updates from a new key) — don't lose it. Document the recovery break protocol in this rule when the key exists.
- **Appcast generation**: `tools/release/generate-appcast.sh` produces `appcast.xml` from the Git tag list + signed DMG hashes. Hosted on GitHub Pages.
- **Release tagging convention**: `v<MAJOR>.<MINOR>.<PATCH>` (semver). `v0.x.y` until the public v1 launch.
- **Pre-release checklist**: spec doc updated for any user-visible change, CLAUDE.md updated if conventions changed, all `factoryPatchable` macros in the bundled seed-macros set re-validated, release notes drafted in the GitHub Release UI before publishing the tag.
- **Roll-back protocol**: if a release breaks users, mark the GitHub Release as pre-release (Sparkle skips it), publish a hotfix `v<x>.<y>.<z+1>` in under an hour. Don't delete releases — Sparkle clients may have already downloaded.

Until the Xcode project exists and the first release is imminent, this is a stub. Re-read when starting on `tools/release/`.
