# R09 — Execution status and interrupt (offline)

Date: 2026-10-05. R09 only; no Phase 1 acceptance. Existing-service, lifecycle, provider and TUI checks are not authorized by this checkpoint. No backend registration/config/database changes, commits or optimized Release tests.

## Source-only contract evidence

Primary re-read raw source at OpenCode v2.0.20 commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`:

- `packages/protocol/src/groups/session.ts` and `packages/server/src/handlers/session.ts`: `GET /api/session/active` returns `{data:{[sessionID]:{type:"running"}}}`. There is no session status GET. This is process-owned execution, not a distributed scheduler.
- `packages/core/src/session/execution.ts`: active ownership includes interruption cleanup/terminal settlement. Interrupt resolves on acceptance; cleanup settles asynchronously. `awaitIdle` exists internally, not as a new client endpoint.
- `packages/core/src/session/run-coordinator.ts`: false also occurs while already stopping or inside the terminal-settlement window, not just idle. The terminal publish hook runs before ownership removal; fresh work admitted during cleanup can create a successor. Therefore neither false nor a historical terminal outcome can substitute for current ownership reconciliation.
- Protocol/handler: `POST /api/session/{id}/interrupt?resume=false`, no payload, returns `200 {interrupted:boolean}` (not a data wrapper). Declared session-not-found error. Busy responses are defensive handling, not a promised interrupt endpoint result. False is not a sufficient current idle observation; reconcile by read.
- `packages/protocol/openapi.json` independently confirms active 200/400/401 and interrupt 200/400/401/404, optional string-encoded boolean query, no request body; no session status path. A 409 is not declared for interrupt.
- `packages/schema/src/session-event.ts`: durable started/succeeded payloads are `{sessionID}`; failed adds `error`; interrupted adds `reason` in `user|shutdown|superseded|inactivity`.
- `packages/schema/src/session-error.ts`: structured error requires `type` and `message`, optional integer HTTP `status` (100–599), optional `response:{body:string}`.
- `packages/schema/src/session-status-event.ts`: ephemeral `session.status` data is `{sessionID,status}`. Idle/busy have only `type`; retry requires nonnegative integer `attempt`, string `message`, nonnegative integer `next`, and an optional structured `action` object (`reason/provider/title/message/label`, optional `link`). Deprecated `session.idle` has `{sessionID}`.
- `packages/schema/src/session.ts`: `Session.Info.outcome` is optional `succeeded|failed|interrupted`, the last completed execution at optional `time.idle`. It is not proof that no newer execution is running.
- `packages/schema/src/event.ts`: durable positions are scoped to one aggregate's log (`aggregateID`, nonnegative integer `seq`, positive `version`). They can suppress older durable execution events within the same context, but cannot order an active-list reply or ephemeral status event.

R08's source-verified live-only stream restrictions remain: no replay/exactly-once/total order; connected is readiness, not a watermark. No source evidence here was exercised against a running service.

## Approval-gated checks — not run

- Interrupt a real provider-backed execution and observe cleanup and terminal state.
- Live active-list/event timing, authentication/error behavior and multi-client/TUI parity.
- Provider-backed permission/form blocking (R10/R11), reconnect/resync (R13), paging/burst acceptance (R14).
- Optimized Release tests remain deferred under D08/N14.

Implementation behavior, provenance and exact offline verification results are recorded below.

### Adapter safety

`API/Execution/ExecutionAPI.swift` requires HTTP 200 and the exact success envelope. Active entries must have a `ses`-prefixed key and `type:"running"`; unknown/malformed types fail the read rather than disappearing from the map and falsely confirming inactivity. Extra fields are tolerated. Interrupt preserves the boolean and sends once only. Declared 400/401/404 responses are rejection facts; unexpected 409 is defensive busy handling, and transport, unexpected statuses and malformed successes are unknown at the application boundary. Cancellation after dispatch is likewise not proof of rejection.

### Review corrections applied in this pass

- **No-session presentation.** A nil selected session now reports a dedicated `noSession` phase ("No session"), not `Idle`. The previous `Idle` fallback was preserved only to satisfy a fixture assertion that never hydrated a session; it was a misleading claim about a session that did not exist. The offline composition test now hydrates the seeded session (as `SessionView` does) and waits for the real empty active read before asserting `Idle`.
- **Structured error field.** `SessionError.Error` reads the pinned `type` field (required) instead of `name`, with `message` primary and a safe placeholder fallback; the raw payload is retained for debugging and never displayed.
- **Retry `action`.** The pinned `session.status` retry `action` is an optional structured object, not a string. The store no longer rejects an otherwise valid retry because of it; the unused `action` is tolerated/ignored.
- **Malformed/unattributable events.** A recognized execution/status event with no attributable session, or a recognized `session.status` whose payload does not parse, now triggers a scoped reread instead of being silently dropped while retaining a possibly stale fact. Neither path can claim stopped (membership stays read-owned and `confirmedStopped` is read-only).

### Presentation boundary

One small status row sits between transcript and composer, with explicit Refresh status and Interrupt controls. A dedicated interrupt action preserves the existing Send/steering semantics rather than changing prompt policy in R09. Views own no subscriptions or observation tasks; application composition binds context publishers and the single event fanout, and stores retain their observations. The DEBUG fixture uses an in-memory active set and source-shaped durable execution events; it is not backend/provider evidence.

### Behavior and provenance

Reads and events write disjoint facts; neither overwrites the other. Every stored fact carries `ExecutionFactProvenance` (session, connection generation, and either the completed read epoch or the event type/id), so a displayed status never mixes facts across sessions or generations.

| Fact | Written by | Provenance source | Guarantee / limit |
|---|---|---|---|
| Running membership (`isActive`) | `GET /api/session/active` only | `.activeRead(epoch:)` | Failed/absent reads never clear it; a malformed or mixed active map fails the whole read closed rather than dropping an entry and falsely confirming inactivity |
| `confirmedStopped` | A fresh inactive read begun after the last relevant interrupt reply | read epoch + request tick | Events alone never set it. A read proves inactivity, not cause, so it reconciles to idle or the last terminal outcome, never to a newly invented "interrupted" |
| Outcome (`lastOutcome`) | `session.execution.started/succeeded/failed/interrupted` | `.event(type:id:)` | The last reported outcome, not a stop. A terminal event with the session still owned by the active list stays **Working** ("Cleanup may still be running"); `blocked` is never produced |
| Liveness (`liveness`) | `session.status`, deprecated `session.idle` | `.event(type:id:)` | Ephemeral hint only; never proves membership. Retry detail surfaces as a reason, never as `blocked`. A malformed status keeps prior facts but triggers a scoped reread |
| Interrupt request (`interruptState`) | Local lifecycle + accepted reply / terminal event / fresh inactive read | request and reply ticks | `accepted` awaits confirmation; `notInterrupted` rereads without a stop claim; `busy`/`failed` report and re-enable explicit retry; `unknown` never re-POSTs and suppresses duplicate taps |
| Attention (`ExecutionAttention`) | Derived (failed outcome, lost interrupt reply) | separate from facts | UI attention never rewrites status; `lastInterruptError`/`attention` are exposed to composition and not yet rendered in the minimal R09 row |
| Phase (`ExecutionPhase`) | Reconciled from the above | — | `noSession`, `idle`, `working`, `completed`, `interrupted`, `failed`, `unknown`; `blocked` reserved for R10/R11 |

Duplicate/staleness handling: durable `seq` suppresses older/duplicate deliveries **within one aggregate and connection generation only** and is never ranked against an active read or an ephemeral status event; ephemeral duplicates use a bounded 256-entry recent-ID window. Stream loss or a failed read keeps prior facts and surfaces stale/unknown, and never claims stopped. Recovery is R13.

## Carried-over boundaries

No token-level streaming/delta application, persistent drafts or send attempts. The existing composer connection-change ambiguity remains R12, including its pre-dispatch window. A lost prompt delivery event still needs another event or manual history Refresh. No reconnect/resync after stream loss (R13), cursor paging or burst acceptance (R14). R09 does not silently implement these or create a backend scheduler.

## R09 limitations and unresolved assumptions

- All evidence is offline against synthetic fixtures. No live service, provider, auth/error-timing, multi-client or TUI parity check was run (see above).
- `busy` is a conservative mapping of an **undeclared** 409; the pinned contract declares only 400/401 for the active read and 400/401/404 for interrupt. A declared rejection and an unknown transport failure remain distinct.
- The active list is the OpenCode process's own foreground drains, not a distributed scheduler: execution owned by another process is invisible, and `Session.Info.outcome` (the last completed execution) is deliberately not used as a current-inactivity signal.
- `lastInterruptError` and `attention` are computed and exposed for composition but are not yet rendered in the minimal status row; the row shows label, `statusReason`, Refresh and Interrupt.
- Durable `seq` dedup relies on the documented per-aggregate ordering; live-only delivery means a genuinely missed event cannot be reconstructed without a fresh read.
- No bounded event-queue/overflow handling beyond the R08 fanout: R09 assumes the R08 fanout's single-subscription failure semantics and does not add replay or resync (R13).

## Verification record (Debug, offline)

Common directory `/private/var/folders/dg/dztwhk5n6rb9xr8jt3t0nkf00000gp/T/opencode/`; derived data `joycode-hardening-derived`; both live opt-ins unset (`env -u JOYCODE_ENABLE_LIVE_TESTS -u TEST_RUNNER_JOYCODE_ENABLE_LIVE_TESTS`). No optimized Release test was run.

| Check | Scope (abridged) | Result | Log |
|---|---|---|---|
| Focused R09 unit tests | `-only-testing:JoycodeTests/ExecutionAPITests -only-testing:JoycodeTests/ExecutionStatusStoreTests -only-testing:JoycodeTests/ExecutionCompositionTests test` | **60 executed** (21 API + 36 store + 3 composition), 0 failures, exit 0 | `joycode-r09-focused-unit-2.log` |
| New offline UI interrupt | `-only-testing:JoycodeUITests/JoycodeUITests/testOfflineFixtureInterruptConfirmsExecutionStatus test` | 1 passed, exit 0 | `joycode-r09-ui-interrupt.log` |
| Full Debug suite (final source) | `-configuration Debug test` | **477 unit executed, 1 live skip, 0 failures; 7 UI, 0 failures**, exit 0 | `joycode-r09-default-debug-final.log` |
| Release build | `-configuration Release build` | `BUILD SUCCEEDED`, exit 0 | `joycode-r09-release-build.log` |
| Debug build | `-configuration Debug build` | `BUILD SUCCEEDED`, exit 0 | `joycode-r09-debug-build.log` |
| pbxproj lint / object IDs | `plutil -lint` + definition scan | OK; 223 unique object definitions, no duplicate IDs | — |
| Swift parse | `swiftc -parse` on changed files | exit 0 | — |

An earlier full-suite run (`joycode-r09-default-debug-full.log`) reported the same counts (477 unit / 1 skip, 7 UI, 0 failures) before a comment-only source edit; the final run above re-verified the final source. The 477 figure is the R08-era 417 plus the R09 additions (54 as integrated) plus 6 further API/store tests added in this pass.

New R09 coverage: `ExecutionAPITests` (request shape/query, exact-200, active decode including empty/extra/mixed-fail-closed and 409-busy, interrupt true/false/malformed, declared errors, transport/cancellation, classification); `ExecutionStatusStoreTests` (membership + provenance, no-session, event outcomes, interrupt-reason fallback, liveness/retry never `blocked`, structured-action tolerance, malformed handling, durable/ephemeral dedup, slow-read epochs/follow-up, session/generation replacement, stream/read failure honesty, full interrupt matrix including lost reply with no re-POST); `ExecutionCompositionTests` (adapter error classification, late-binding readiness/failure, offline no-session→hydrated idle). The DEBUG fixture's in-memory backend is not provider evidence.
