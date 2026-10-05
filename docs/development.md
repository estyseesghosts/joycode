# Joycode development

## F02 baseline

Joycode is a native macOS SwiftUI application in `Joycode.xcodeproj`; it has app,
unit-test, and UI-test targets. The deployment target is macOS 26.0. This slice has
no networking, service operations, provider calls, or OpenCode runtime behavior.

The verified local toolchain is **Xcode 26.6 (17F113)** and **Swift 6.3.3**.

## Reproducible checks

Run from the repository root. The shared `Joycode` scheme is the source of truth and
`platform=macOS` selects the local macOS destination:

```sh
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' build
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' test
```

`xcodebuild` returns a non-zero status when compilation or any selected unit/UI test
fails; do not mask that status with `|| true`. The default test command includes the
pure smoke unit test and launch/window UI smoke test. The live arrangement is skipped.

## Opt-in live diagnostic

The live diagnostic test remains skipped by the default test command. To run it, first
start only an explicitly approved disposable v2.0.20 sandbox using the verified procedure
and isolated state. Then set all of these values for the test process:

```sh
TEST_RUNNER_JOYCODE_ENABLE_LIVE_TESTS=1 \
TEST_RUNNER_JOYCODE_LIVE_ENDPOINT='http://127.0.0.1:<sandbox-port>' \
TEST_RUNNER_JOYCODE_LIVE_CONTEXT=approved-disposable \
TEST_RUNNER_JOYCODE_LIVE_SANDBOX_ROOT='/path/to/private-sandbox' \
TEST_RUNNER_XDG_STATE_HOME='/path/to/private-sandbox/state' \
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' \
  -only-testing:JoycodeTests/LiveOptInTests/testProductionDiagnosticConnectsToApprovedPinnedSandbox test
```

The test verifies that the endpoint is loopback, the registration file is inside the
private sandbox with expected permissions and matching URL, and the registered version is
exactly `2.0.20`. It uses the existing production diagnostic composition to call only
`GET /api/info` and `GET /api/event`, waits for the sanitized `server.connected` status,
then disconnects. It does not inspect the registration password or event payload and does
not call session/provider endpoints. The default test command remains offline. Starting the
sandbox is a separate, explicitly authorized setup action; the test itself never starts a
service. Never point these settings at the user's normal service registration.

For the focused R02 stream-failure scenario, additionally set
`TEST_RUNNER_JOYCODE_LIVE_EXPECT_STREAM_FAILURE=1`. The test disconnects and reconnects,
then creates `<sandbox-root>/joycode-r02-ready` only after the second stream marker. An
external harness may then stop only the isolated sandbox process to verify that stream
failure is visible while the service connection remains connected. The test never starts or
stops a process; the harness must use a disposable context and remove it afterward. The
marker is a readiness signal, not a new P0 capture or broad acceptance claim.

## F10 / Phase 0 Release check status

**2026-10-05 audit correction:** the current ProjectPickerTests suite has 14 tests. The last audit default Debug suite passed (201 executed, 200 passed, one live skip, zero failures), including one launch UI smoke test; historical runner timeouts did not reproduce. Historical Release-requested compilation resolved to Debug and did not validate a separate Release artifact. Fresh configuration repair/settings/build results are in [H03](plan/r05-build-boundary-2026-10-05.md); the historical narrative below is not current Release artifact proof. Release tests remain deferred and require separate approval/disposition under D08/N14.

The prior Debug baseline was 84 unit test cases (83 passed and one skipped opt-in live test), one UI smoke test passed, and the Debug app build passed. The current focused offline result is 199 passed, 1 skipped, 0 failures (200 executed; 13 R03 ProjectPickerTests, 26 R04 SessionStoreTests, 26 R04a SessionRename tests, and 46 R05 Selection tests); the opt-in live test passed 1/1 and fixture-focused tests passed 15. A default full build/test attempt hung/faulted in Xcode's test runner/UI-test initialization; it was not an assertion failure and is not a new full-suite pass. On
2026-10-01, F10 ran the following Release configuration commands sequentially with live
test environment variables removed:

```sh
env -u JOYCODE_ENABLE_LIVE_TESTS -u JOYCODE_LIVE_ENDPOINT -u JOYCODE_LIVE_CONTEXT \
  xcodebuild -project Joycode.xcodeproj -scheme Joycode -configuration Release -destination 'platform=macOS' build
env -u JOYCODE_ENABLE_LIVE_TESTS -u JOYCODE_LIVE_ENDPOINT -u JOYCODE_LIVE_CONTEXT \
  xcodebuild -project Joycode.xcodeproj -scheme Joycode -configuration Release -destination 'platform=macOS' test
```

The Release `build` passed. The Release `test` attempt failed while compiling tests:
`@testable import Joycode` could not resolve a compatible module. The shared scheme has
`TestAction buildConfiguration="Debug"`, and the Release app module lacks
`ENABLE_TESTABILITY=YES`; the test-host configuration does not support this Release test
 invocation. No Release tests ran, and this is a harness/configuration incompatibility, not
 a runtime test failure. The user explicitly chose to defer Release tests rather than add a
 `ReleaseTest` configuration now; do not rerun it unchanged. Revisit at N14: either use a
 dedicated optimized `ReleaseTest` configuration/scheme (test host only; not distributable
 Release) and record counts/skips, or record an explicit N14-approved disposition to ship
 without optimized Release tests.
Live variables were removed for the Release build/test invocations; the separate approved
v2.0.20 opt-in diagnostic later passed against the disposable sandbox. No provider call or
session mutation was made. This limitation was explicitly excluded from the Phase 0 final gate
by the user; Phase 0/F10 is complete on 2026-10-01, while D08 remains open for N14. See [the staged Release plan](plan/release-binary-validation.md), [the deferred work
ledger](plan/deferred-work.md) and [verification](plan/verification-and-coverage.md).
