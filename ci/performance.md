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
- **Caching:** simulator compilation caching is implemented below. There are no
  Swift package dependencies to cache. SDKs and simulator runtimes are large and
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

## Compilation caching

Simulator CI now enables Xcode 26's content-addressed compilation cache using
`COMPILATION_CACHE_ENABLE_CACHING=YES` and an explicit
`COMPILATION_CACHE_CAS_PATH`. `actions/cache@v5` persists only that directory.
Build products, DerivedData's incremental database, SDKs, and simulator runtimes
are not restored. Each runner still generates the project and performs a build;
Xcode validates compiler inputs and replays matching cached compilation results.

The compatibility prefix includes the Xcode version/build, SDK build, macOS build,
runner architecture, checkout location, SDK, configuration, project specification,
and cache action definition. The commit SHA identifies each immutable snapshot;
a prefix restore allows reuse across source commits. GitHub retains its normal
branch/PR cache isolation and eviction policy. A missing or evicted snapshot
simply requires compiling again. Bump `xcode-cas-v1` in the local action to
invalidate all snapshots if needed.

Device archives are intentionally excluded: they run on unique release tags,
and GitHub does not allow one tag to restore another tag's snapshot. The default
branch does not populate a device Release cache. Adding such a cache only to the
tag job would add storage/upload work without cross-release reuse.

### Reproducing measurements

Dispatch CI on the same branch with `use_cache=false` for an uncached baseline.
Then dispatch with `use_cache=true`; the first compatible run populates the cache,
and subsequent runs restore it. Keep app source, Xcode, SDK, and runner image the
same. Compare the Build step and the full job (including cache restore/save),
and inspect compiler cache-hit remarks in the `simulator-build-log` artifact.
The job summary reports an exact snapshot match; a prefix snapshot can still
produce compiler hits even when that field is false.

```sh
gh workflow run ci.yml --ref ci/compilation-cache -f use_cache=false
# Wait for each run to complete before dispatching the next (concurrency cancels overlaps).
gh workflow run ci.yml --ref ci/compilation-cache -f use_cache=true
```

References: [Xcode 26 compilation caching](https://developer.apple.com/documentation/Xcode-Release-Notes/xcode-26-release-notes),
[cache action](https://github.com/actions/cache), and
[GitHub cache scope restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).
