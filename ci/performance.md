# CI performance review

Baseline: successful runs on 2026-11-19, commit `b519c11`, hosted
`macos-15-arm64` image, Xcode 26.3. These are small samples; runner load and
Apple's upload service affect elapsed time.

| Step | Main run 44466935969 | Main run 44466409452 | Tag run 44466938731 |
| --- | ---: | ---: | ---: |
| Tools + SDK check | 11 s | 13 s | 7 s |
| Simulator build | 48 s | 67 s | 45 s |
| Artifact upload | 2 s | 2 s | 2 s |
| Release tools + generation | — | — | 11 s |
| Device archive | — | — | 54 s |
| Export + TestFlight upload | — | — | 46 s |
| Entire workflow, including orchestration | 73 s | 95 s | 186 s |

Sources: [latest main run](https://github.com/danielelisi/vision-pipeline/actions/runs/44466935969),
[previous main run](https://github.com/danielelisi/vision-pipeline/actions/runs/44466409452),
[successful release](https://github.com/danielelisi/vision-pipeline/actions/runs/44466938731).

## Changes

- Set `ARCHS=arm64` for the simulator build. Logs showed every Swift source
  compiled for both ARM64 and x86_64 and universal binaries linked. CI and the
  documented local development environment use Apple silicon. This reduces
  compilation and linking work, but drops Intel simulator artifact support.
  Device archive architecture settings remain the Xcode defaults.
- Install only missing tools. `xcbeautify` was already on the runner, while
  XcodeGen was downloaded each time. Disable Homebrew update and cleanup during
  setup, following the [Homebrew environment settings](https://docs.brew.sh/Manpage).
- Share setup through `ci/setup.sh`, and check the actual SDK required by each
  job (`xrsimulator` or `xros`). Retain platform download as a fallback and verify
  the SDK afterward. A simulator runtime is not required for a compile-only job.
- Add `-showBuildTimingSummary` to build and archive so subsequent optimization
  can use compiler task timings. See [Apple's build timing guidance](https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds).

## Validation result

[Branch run 44496519009](https://github.com/danielelisi/vision-pipeline/actions/runs/44496519009)
passed on the same runner image and Xcode version. Setup plus generation took
11 seconds, the build took 52 seconds, artifact upload took 2 seconds, and the
whole workflow took 83 seconds (77 seconds within the build job). Logs confirm
ARM64 compilation with no x86_64 compilation or universal linking.

This is within the baseline range, so **a wall-clock speedup is not established**.
The changes remove redundant work, but a larger paired sample is needed to
separate their effect from hosted-runner variance. Homebrew still downloads
XcodeGen; skipping the preinstalled formatter did not measurably shorten setup
in this sample. Actionlint, shell syntax, and mocked setup branches also passed.
The signed archive/export path was not exercised; branch manual dispatch runs
only the simulator job.

Compare build and setup steps separately from total time and repeat if runner
variance is larger than the difference.

## Further options

- **Release critical path:** the tag workflow waits roughly a minute for the
  simulator check before archiving. Main and tag pushes also validate the same
  commit separately. Keeping this gate is intentional in this change. A future
  design could archive alongside simulator validation, then gate export/upload
  on both succeeding. That requires transferring a signed archive between jobs
  and measuring the transfer overhead. Simply dropping `needs: build` would
  remove the existing release gate.
- **Caching:** there are no Swift package dependencies. DerivedData caching may
  help as the app grows, but download/upload overhead and Xcode's handling of
  source timestamps need measurement against a build that currently takes less
  than 70 seconds. Do not cache SDKs or simulator runtimes; they are large and
  already installed in the measured runs.
- **Artifacts:** uploading the roughly 4 MB simulator artifact took only two
  seconds. Retain it on every build; tuning compression has little headroom.
- **Documentation changes:** skipping app compilation for docs-only PRs could
  save runner time. Implement change detection inside the workflow if the build
  check is required, so it still reports success instead of remaining pending.
- **Runner/toolchain:** `macos-15` already resolves to Apple silicon in these
  logs. Moving to an ARM runner is therefore not an additional optimization.
  `latest-stable` adds little setup time; pin Xcode for reproducibility if
  desired, rather than expecting a speed improvement from that alone.
