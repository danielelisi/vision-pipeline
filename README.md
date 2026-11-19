# Vision Pipeline

A deliberately tiny visionOS app ("Hello, Vision Pro") used to get CI/CD right before
applying it to real projects.

## Pipeline

| Trigger | Job | What happens |
|---|---|---|
| push / PR / manual | **Build** | `macos-15` runner → latest Xcode → `xcodegen generate` → build for the visionOS simulator (unsigned) → `.app` uploaded as an artifact |
| tag `v*` | **Ship to TestFlight** | archive with cloud-managed signing via an App Store Connect API key → upload to TestFlight |

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
