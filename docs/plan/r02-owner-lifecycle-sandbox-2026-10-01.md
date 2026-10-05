# R02 owner lifecycle sandbox check — 2026-10-01

**Status: focused current-code event-owner failure/reconnect/cancellation check passed; full R01/R02 acceptance remains open.** This note records only the newly implemented owner lifecycle scenario. It does not replace or extend the narrow base evidence in [the P0 sandbox record](p0-v2.0.20-sandbox-2026-10-01.md).

## Approval and isolation

- The user authorized a new disposable OpenCode v2.0.20 check, explicitly excluding their live service and ongoing work.
- The service was launched manually from the pinned v2.0.20 artifact in a fresh private temporary root. `HOME`, `OPENCODE_TEST_HOME`, XDG state/config/data/cache, OpenCode config, temporary files, and Xcode DerivedData/test results were isolated under that root. The app itself used explicit Connect and did not launch or manage the service.
- The official npm registry integrity, extracted executable SHA-256, and self-reported version matched the already-recorded P0 artifact provenance. The server used `OPENCODE_DB=:memory:`, loopback `127.0.0.1` with an OS-assigned port, project-config loading disabled, and model-fetch/update safeguards. Its private registration was mode `0600`; the registration directory was tightened to `0700` before the test.
- No provider calls, session endpoints, session mutations, TUI, or existing service were used. Credentials, temporary paths, endpoint, port, PID, response bodies, and event payloads were not retained here.

## Scenario and result

- The opt-in `LiveOptInTests.testProductionDiagnosticConnectsToApprovedPinnedSandbox` ran against the current production composition with exact v2.0.20 enforcement.
- The connection/event owners connected, observed `server.connected` only as an in-test readiness signal, explicitly disconnected, cleared owner state, and connected again. The harness then waited for the private readiness sentinel and stopped only the isolated server process it had launched.
- The event owner surfaced stream termination as a subscription failure while the R01 connection state remained `.connected(version: "2.0.20")`. The test then explicitly disconnected and passed: 1 test, 0 failures.
- This check did not retain a new `/api/info` or event capture, and the readiness marker is not claimed as new P0 evidence.

## Cleanup and limitations

- The isolated service process was reaped, its listener closed, and the temporary sandbox root and generated registration were removed. Joycode did not stop or restart the service; the test harness stopped only its own approved disposable process.
- This is focused production-owner runtime evidence, not broad workflow or TUI coexistence proof. It does not close R01 or R02 acceptance. The earlier P0 record remains the source for its narrow base endpoint/marker/coexistence checks; broader lifecycle, error, and owner-gate evidence remains open in the [deferred-work ledger](deferred-work.md).
