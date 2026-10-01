# Release binary validation plan

This is a staged offline validation plan. The 2026-10-01 F10 attempt ran the unsigned
Release compile check, but did not establish a Release test result. By explicit user decision,
optimized Release testing is deferred to N14 and was explicitly excluded from the Phase 0 final gate by the user. This plan does not authorize
signing, distribution, provider calls, backend access, or release operations.

## Early offline F10 check

Use the established project, scheme, and macOS destination from `docs/development.md`.
The following commands were attempted sequentially on 2026-10-01 with the live-test
environment variables removed:

```sh
env -u JOYCODE_ENABLE_LIVE_TESTS -u JOYCODE_LIVE_ENDPOINT -u JOYCODE_LIVE_CONTEXT \
  xcodebuild -project Joycode.xcodeproj -scheme Joycode -configuration Release -destination 'platform=macOS' build
env -u JOYCODE_ENABLE_LIVE_TESTS -u JOYCODE_LIVE_ENDPOINT -u JOYCODE_LIVE_CONTEXT \
  xcodebuild -project Joycode.xcodeproj -scheme Joycode -configuration Release -destination 'platform=macOS' test
```

The Release `build` command **passed**. The Release `test` command **failed while compiling
tests**, before tests ran: `@testable import Joycode` could not resolve a compatible module.
The shared scheme's TestAction uses `buildConfiguration="Debug"`, while the Release app
module lacks `ENABLE_TESTABILITY=YES`; its test-host configuration does not support this
Release invocation. This is harness/configuration incompatibility, not a runtime test
failure. Do not rerun this command unchanged or claim Release tests passed or ran.

This compile result proves only unsigned Release-configuration compilation. It does **not**
prove a signed or distributable artifact, Release test evidence, backend provenance, live
service behavior, or provider behavior. Live variables were removed during these Release
invocations. Separately, the approved pinned-sandbox diagnostic later passed 1/1 without a
provider call. The earlier Debug baseline had 84 unit test cases (83 passed and one skipped
opt-in live test), one UI smoke test passed, and the Debug app build passed; see the current
focused counts in [verification](verification-and-coverage.md).

The user chose to defer Release testing rather than add a `ReleaseTest` configuration now.
D08 remains an open tracked limitation. At N14, before the final artifact gate, either run a
dedicated optimized `ReleaseTest` configuration with `ENABLE_TESTABILITY=YES` only for the
test host (not the distributable Release), or record an explicit N14-approved disposition to
ship without optimized Release tests. Until N14, do not rerun the known-failing command
unchanged. Do not run provider or live checks as part of this documentation slice.

## Later distribution stages

1. **N11 — channel and install model.** Choose direct distribution or store, architecture(s),
   minimum OS, sandbox and dependency/service model. Then archive/export and test clean-machine
   or clean-account install, launch, upgrade and uninstall without deleting OpenCode data.
   Archive/export commands remain deferred until the channel and identity choices are made;
   no unverified command is prescribed here.
2. **N12 — signing and notarization.** With an authorized identity and credentials outside
   the repository, verify signing, notarization/stapling and Gatekeeper behavior. Without
   those credentials this stage is honestly blocked, not passed.
3. **N13 — update and rollback.** For the selected channel, verify authenticated update,
   interruption/failure, compatibility, integrity/tamper rejection, rollback and preservation
   of local preferences/sessions. Do not silently update the shared backend.
4. **N14 — final artifact gate.** Revisit D08 first: record the dedicated optimized
   `ReleaseTest` result, or the explicit N14-approved disposition to ship without optimized
   Release tests. Then record the selected channel, all earlier gate results, final artifact
   evidence and approved TUI/workflow dispositions. A Release app compile alone cannot close
   N14 and is distinct from Release testing and artifact/distribution proof.

## Required evidence

Record exact Xcode, Swift and macOS versions; configuration and destination; artifact path
and hash; architectures, bundle/version and deployment target; test counts and skipped tests;
and launch, install and signature status. Keep signing secrets, identities and tokens out of
the repository and logs. Link results from the [deferred-work ledger](deferred-work.md).
