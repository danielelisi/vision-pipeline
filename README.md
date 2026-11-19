# Vision Pipeline

A deliberately tiny visionOS app ("Hello, Vision Pro") used to get CI/CD right before
applying it to real projects.

## Pipeline

| Trigger | Job | What happens |
|---|---|---|
| push / PR / manual | **Build** | `macos-15` runner → latest Xcode → `xcodegen generate` → build for the ARM64 visionOS simulator (unsigned) → `.app` uploaded as an artifact |
| tag `v*` | **Ship to TestFlight** | archive with cloud-managed signing via an App Store Connect API key → upload to TestFlight |

CI installs only missing tools and disables Homebrew auto-update/cleanup on the
disposable runner. Both build jobs print Xcode timing summaries. The simulator
artifact targets Apple silicon; it does not include an Intel simulator binary.
The TestFlight job still waits for the simulator build to pass.

See [the CI performance review](ci/performance.md) for baseline measurements and
further options.

## Local

```sh
brew install xcodegen
xcodegen generate && open VisionPipeline.xcodeproj
```

Requires an Apple silicon Mac.

## TestFlight setup (one time)

1. Apple Developer Program membership.
2. App Store Connect → Apps → **+** → visionOS app with bundle ID `dev.daniele.visionpipeline`.
3. App Store Connect → Users and Access → Integrations → **App Store Connect API** → create a key with the **Admin** role.
4. Add repo secrets:
   - `ASC_KEY_ID`, `ASC_ISSUER_ID`
   - `ASC_KEY_P8_BASE64`: `base64 -i AuthKey_XXXX.p8 | pbcopy`
   - `APPLE_TEAM_ID`
5. `git tag v1.0.1 && git push --tags` (versions must be > 1.0.0)
