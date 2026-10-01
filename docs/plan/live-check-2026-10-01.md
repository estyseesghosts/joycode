# Read-only local live check — 2026-10-01

## Scope and provenance

- User authorized a read-only check of the already-running local OpenCode instance at `127.0.0.1:49374`; no service was started or restarted.
- The local registration file had mode `0600`. Its URL and PID matched the listener. Its configured password was used to authenticate the requests; the password value was not printed or persisted in this record.
- Registration and `/api/info` both identified OpenCode `2.0.21`; the registered PID matched the PID reported by `/api/info`.
- This is **not** the roadmap's pinned `v2.0.20` target. No compatibility claim is made for this off-pin version.

## Observations

| Check | Result |
|---|---|
| Unauthenticated `GET /api/info` | `401`, as expected for this password-protected service. |
| Authenticated `GET /api/info` | `200`; reported version and PID matched the sanitized registration metadata. The response's paths were not recorded. |
| Authenticated `GET /api/event` | `200 text/event-stream`; first event type was `server.connected`. The client explicitly closed the response after that marker. No event payload was retained. |

Only `/api/info` and `/api/event` were requested. No session endpoints, provider calls, or session mutations were made. No session payload was inspected or saved. The stream could receive events caused by other clients while it was open; only the first event's type was extracted.

## Limitations / gate status

- This was a direct local HTTP probe, not a Joycode UI connection or connection-owned subscription test.
- The official TUI was not run alongside Joycode; no runtime coexistence or TUI parity evidence was collected.
- **Historical status at the time of this off-pin probe:** the pinned-version, disposable-context and official-TUI evidence had not yet been collected; this record did not claim F10/P0/R01/R02 complete. The later pinned sandbox evidence and Phase 0 gate decision are documented in [the sandbox record](p0-v2.0.20-sandbox-2026-10-01.md) and [Phase 0 plan](phase-0-foundation.md). This off-pin check remains non-pinned evidence and does not close the full R01/R02 feature gates.
