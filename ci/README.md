# CI performance review

Baseline: GitHub Actions runs from November 19, 2026 (UTC), before these changes.
Step timings exclude runner queue time. Runs vary enough that a single comparison
cannot establish the size of an improvement.

| Step | Observed duration | Evidence |
|---|---|---|
| Tools and SDK check | 7–13 s | Seven sampled successful simulator jobs |
| Simulator build | 45–198 s | Same seven jobs; logs show both arm64 and x86_64 compilation |
| Simulator artifact upload | 2–4 s | Same seven jobs |
| Device archive | 54–64 s | Successful `v0.2.1` and `v0.1.1` releases |
| Export and TestFlight upload | 46–53 s | Same two releases |

Examples: [latest main build](https://github.com/danielelisi/vision-pipeline/actions/runs/44466935969)
(73 s overall), [slow main build](https://github.com/danielelisi/vision-pipeline/actions/runs/44464604033)
(222 s overall), [latest successful release](https://github.com/danielelisi/vision-pipeline/actions/runs/44466938731)
(186 s overall).

## Changes

- Build the simulator for arm64 only. The generic simulator destination previously
  compiled both arm64 and x86_64, including separate Swift modules and link steps.
  The project requires Apple silicon locally; the artifact now targets that hardware.
  Device archive architecture settings retain Xcode's defaults.
- Reuse installed tools; install only missing tools with Homebrew auto-update and
  install cleanup disabled. Logs showed xcbeautify was already installed.
- Check the exact SDK (`xrsimulator` for the simulator, `xros` for the archive).
  Missing SDKs fail with a clear error. Generic builds do not need a running
  simulator; the previous `-downloadPlatform` fallback could trigger an unnecessary
  runtime download. SDK checks no longer use an early-exiting grep pipeline under
  `pipefail`.
- Skip documentation-only pushes to main. Leave PR checks unfiltered so required
  checks can complete, and keep tag releases and manual runs available.
- Add `-showBuildTimingSummary` to simulator builds and device archives, following
  [Apple's measurement guidance](https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds).

## Follow-up options

The release job waits for the simulator build although it does not consume its
artifact. Removing `needs: build` would allow both jobs to start together, saving
roughly 60 s on the latest release. This also permits TestFlight uploads when the
simulator build fails, so it is a release-policy decision.

There are no external package dependencies to cache. Consider DerivedData caching
only after collecting the new build timing summaries. Measure restore/save costs,
key by Xcode version, platform and architecture, and preserve input modification
times before expecting incremental build reuse. Do not share simulator outputs
with device archives.

Artifact upload takes only 2–4 s, so changing compression or removing the artifact
has little potential benefit. Xcode selection takes 0–1 s and is also not a
meaningful bottleneck. Pinning Xcode could improve reproducibility but does not
address the measured delay.

Compare several runs at the same source revision and Xcode version to measure
the architecture change independently of runner variability. The Linux workspace
cannot compile this visionOS app; a successful GitHub macOS run is required for
build validation.
