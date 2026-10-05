# H03 — Build Configuration Boundary

## Integrated hardening/API boundary follow-up

Primary reran the authorized Release **build** after hardening, prompt/history adapter corrections and DEBUG-only offline UI-fixture integration. Established command: `xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -configuration Release -derivedDataPath '/private/var/folders/dg/dztwhk5n6rb9xr8jt3t0nkf00000gp/T/opencode/joycode-hardening-derived' build`; exit0. Log: `joycode-hardening-integrated-release-build.log`. Compiler again used `-O -DRELEASE`, distinct Release products/intermediates. Read-only byte inspection of the Release executable found none of the three DEBUG fixture markers (`--joycode-offline-ui-fixture`, temporary fixture prefix, fixture session title). This is build/exclusion evidence only, **not** optimized Release-test or distribution acceptance. Later R06/R07 store/view edits require new checks; D08/N14 remains open.

**Date:** 2026-10-05
**Owner:** H03 subagent
**Status:** Settings independently verified by primary; H03 boundary and integrated hardening/API Release builds passed. Later R06/R07 store/view edits await verification. No Release tests executed.

---

## Problem

The project-level `XCConfigurationList` (`A10000500000000000000004`) contained only a single Debug configuration with minimal settings (`MACOSX_DEPLOYMENT_TARGET`, `SWIFT_VERSION`). There was no project-level Release configuration. Optimization levels, testability, and compilation conditions were not explicitly set, relying on fragile Xcode defaults.

## Changes

### File: `Joycode.xcodeproj/project.pbxproj`

**1. Enriched project-level Debug config (`A10000800000000000000004`)**

Added explicit settings:

| Setting | Value |
|---|---|
| `CLANG_ENABLE_MODULES` | `YES` |
| `COPY_PHASE_STRIP` | `NO` |
| `ENABLE_TESTABILITY` | `YES` |
| `GCC_OPTIMIZATION_LEVEL` | `0` |
| `MTL_ENABLE_DEBUG_INFO` | `INCLUDE_SOURCE` |
| `ONLY_ACTIVE_ARCH` | `YES` |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `"DEBUG $(inherited)"` |
| `SWIFT_OPTIMIZATION_LEVEL` | `"-Onone"` |
| `MACOSX_DEPLOYMENT_TARGET` | `26.0` *(preserved)* |
| `SWIFT_VERSION` | `6.0` *(preserved)* |

**2. Added project-level Release config (`A10000800000000000000008`)**

| Setting | Value |
|---|---|
| `CLANG_ENABLE_MODULES` | `YES` |
| `COPY_PHASE_STRIP` | `YES` |
| `ENABLE_TESTABILITY` | `NO` |
| `GCC_OPTIMIZATION_LEVEL` | `s` |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `"RELEASE $(inherited)"` |
| `SWIFT_OPTIMIZATION_LEVEL` | `"-O"` |
| `MACOSX_DEPLOYMENT_TARGET` | `26.0` |
| `SWIFT_VERSION` | `6.0` |

**3. Updated project-level config list (`A10000500000000000000004`)**

```
// Before
buildConfigurations = (A10000800000000000000004);

// After
buildConfigurations = (A10000800000000000000004, A10000800000000000000008);
```

### Preserved (no changes)

- All 6 target-level configs unchanged (A10000800000000000000001–A10000800000000000000007)
- All 3 target-level config lists unchanged (A10000500000000000000001–A10000500000000000000003)
- Scheme (`Joycode.xcscheme`) unchanged — TestAction uses Debug, ProfileAction/ArchiveAction use Release
- All PBXBuildFile, PBXFileReference, PBXNativeTarget, PBXProject objects unchanged

---

## Verified Settings (`-showBuildSettings`)

### Debug (`-configuration Debug`)

| Setting | Resolved Value |
|---|---|
| `CONFIGURATION` | `Debug` |
| `SWIFT_OPTIMIZATION_LEVEL` | `-Onone` |
| `ENABLE_TESTABILITY` | `YES` |
| `GCC_OPTIMIZATION_LEVEL` | `0` |
| `ONLY_ACTIVE_ARCH` | `YES` |
| `COPY_PHASE_STRIP` | `NO` |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `DEBUG` |
| `BUILT_PRODUCTS_DIR` | `…/Build/Products/Debug` |
| `CONFIGURATION_BUILD_DIR` | `…/Build/Products/Debug` |
| `CONFIGURATION_TEMP_DIR` | `…/Intermediates.noindex/Joycode.build/Debug` |
| `TARGET_TEMP_DIR` | `…/Intermediates.noindex/Joycode.build/Debug/Joycode.build` |

### Release (`-configuration Release`)

| Setting | Resolved Value |
|---|---|
| `CONFIGURATION` | `Release` |
| `SWIFT_OPTIMIZATION_LEVEL` | `-O` |
| `ENABLE_TESTABILITY` | `NO` |
| `GCC_OPTIMIZATION_LEVEL` | `s` |
| `ONLY_ACTIVE_ARCH` | `NO` |
| `COPY_PHASE_STRIP` | `YES` |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `RELEASE` |
| `BUILT_PRODUCTS_DIR` | `…/Build/Products/Release` |
| `CONFIGURATION_BUILD_DIR` | `…/Build/Products/Release` |
| `CONFIGURATION_TEMP_DIR` | `…/Intermediates.noindex/Joycode.build/Release` |
| `TARGET_TEMP_DIR` | `…/Intermediates.noindex/Joycode.build/Release/Joycode.build` |

### Distinct Paths Confirmed

- Products: `…/Products/Debug/` vs `…/Products/Release/`
- Intermediates: `…/Joycode.build/Debug/` vs `…/Joycode.build/Release/`

---

## Build Commands (for H01 / primary agent)

These commands were **not** run by this subagent. They should be run by the primary agent or H01 test agent:

```bash
# Debug build (safe to run)
xcodebuild -project Joycode.xcodeproj -scheme Joycode -configuration Debug build

# Debug test (safe to run)
xcodebuild -project Joycode.xcodeproj -scheme Joycode -configuration Debug test

# Release build (verify compilation only, no tests)
xcodebuild -project Joycode.xcodeproj -scheme Joycode -configuration Release build
```

**NOT run and NOT approved by this agent:**
- `xcodebuild -configuration Release test` — requires separate approval (D08/N14 disposition)
- No commits, no service/provider changes, no subagent spawning

---

## Non-Goals

- Running builds or tests (deferred to H01 agent)
- Running Release tests or closing D08/N14 (requires separate approval)
- Modifying target-level configurations
- Modifying scheme files
- Any service, provider, or communication changes

## Primary verification

The primary inspected the project configuration objects and independently ran:

```sh
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -configuration Release -showBuildSettings
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -configuration Debug -showBuildSettings
env -u JOYCODE_ENABLE_LIVE_TESTS -u JOYCODE_LIVE_ENDPOINT -u JOYCODE_LIVE_CONTEXT xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -configuration Release -derivedDataPath '/private/var/folders/dg/dztwhk5n6rb9xr8jt3t0nkf00000gp/T/opencode/joycode-hardening-derived' build
```

Settings resolved Debug `-Onone`, testability YES, `IS_UNOPTIMIZED_BUILD=YES`; Release `-O`, testability NO, `IS_UNOPTIMIZED_BUILD=NO`. Products and configuration intermediates are distinct Debug/Release directories. The build exited 0 with `BUILD SUCCEEDED`; Swift compiler invocation contains `-O -DRELEASE` and writes `Products/Release/Joycode.app`. This is fresh Release compilation evidence, not optimized Release test, distribution, signing/notarization or final integrated-workflow evidence. Build log is retained in the approved temporary directory as `joycode-hardening-release-build.log`.

D08/N14 remains open. A separate approval for optimized ReleaseTest work or an approved disposition is still needed; the known-failing Release test command was not rerun.
