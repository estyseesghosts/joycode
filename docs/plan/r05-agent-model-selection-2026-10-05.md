# R05 — Primary agent and model selection slice record (2026-10-05)

[Phase 1](phase-1-single-session.md) · [Verification](verification-and-coverage.md) · [Deferred work](deferred-work.md)

## Scope and evidence boundary

R05 follows R04/R04a and delivers discovered primary-agent and model selection with
independently maintained selection. It adds discovery adapters and a `Features/Selection/`
view; it does not add local Plan-mode enforcement, model variants, authentication/provider
settings, or polished Phase-5 chrome.

All checks in this slice are offline. No access to the user's service, service startup,
provider calls, or live session mutations is authorized. The earlier disposable R01/R02
approval does not authorize a new live run. Live selection behavior and TUI agreement
require separate approval and remain open under D05; R01/R02 gates D03/D04 and Release
testing D08 remain open.

The offline implementation, review findings/fixes, and exact verification results are
recorded below. No live, provider, UI-suite, or Release acceptance is claimed.

## Pinned contract verification (before implementation)

A fresh read-only `opencode-contract-researcher` verified the pinned v2.0.20 sources
(official tag resolves to commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`). Source
evidence only:

- **Agent discovery:** `GET /api/agent`; optional `location[directory]` deep-object query
  (location middleware); `200 {location, data: Agent.Info[]}`; declared `400
  InvalidRequestError` / `401 UnauthorizedError`. `Agent.Info` required fields include
  `id`, `name`, `mode` (`"subagent" | "primary" | "all"`), `hidden`; `description` is
  optional. `additionalProperties: false`.
- **Model discovery:** `GET /api/model`; optional `location[directory]`; `200 {location,
  data: Model.Info[]}`; declared `400` / `401` / `503 ServiceUnavailableError`. `Model.Info`
  carries `id`, `providerID`, `name?`, `enabled`, `status` (plus cost/capability metadata).
  `Model.Ref` is `{id, providerID, variant?}`.
- **Agent selection:** `POST /api/session/{sessionID}/agent`, body `{agent: string}`
  (the `Agent.Info.id`), success `204`, declared `400` / `401` / `404`. Context resolves
  from the pinned session; there is no query `location`.
- **Model selection:** `POST /api/session/{sessionID}/model`, body `{model: Model.Ref}`,
  success `204`, declared `400` / `401` / `404`. Pinned session context.
- **Readback:** `Session.Info` carries optional `agent`/`model`, so `GET /api/session/{id}`
  provides an authoritative selection read. Session create carries optional `agent`
  (string) and `model` (`Model.Ref`); prompt does **not** carry agent/model (they are
  session-level).
- **Discovery vs selection context:** discovery uses the `location[directory]` middleware;
  selection mutations resolve context from the pinned session. Confirmed in the location
  middleware wiring and the session handlers.

## Acceptance matrix

| Acceptance | Required evidence |
|---|---|
| Discover available primary agents/models truthfully | Pinned `GET /api/agent` and `GET /api/model` adapters; view renders `mode`-filtered agents and enabled models, with a truthful fallback when discovery is absent/failed. |
| Selection applies through documented operations, success only after `204` | `POST …/agent` and `POST …/model` adapters; store publishes a selection only on `.applied`; best-effort documented readback never fabricates. |
| Agent switch retains a valid model; model switch retains the agent | Independent store state; apply logic only adopts an authoritative counterpart when present. |
| Absent/disallowed agents/models produce a truthful error | Local guard rejects undiscovered/disabled values without calling; declared `400/401/404` become `.rejected`; 5xx/transport become `.unknown`. |
| Configured values are not hardcoded; unknown fields do not crash | No literal agent/model IDs; tolerant decoders ignore extra keys and default optional fields. |
| Late/stale responses cannot regress newer state or another session | Discovery/selection/session-sync generations plus an active-session guard. |
| Live selection behavior and TUI agreement | **Open:** separate approved disposable live check required (D05). |

## Environment

- Xcode 26.6 (17F113), Apple Swift 6.3.3; native macOS app deployment target 26.0.
- Contract pin: OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`.
- Test scope: synthetic/injected offline responses only; no new sanitized live captures.

## Baseline checks

Before implementation, both requested Debug commands were rerun successfully on the frozen
R04a artifact:

```sh
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' build
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -only-testing:JoycodeTests test
```

Build tail: `** BUILD SUCCEEDED **`. Test tail: `Executed 154 tests, with 1 test skipped
and 0 failures (0 unexpected)`; `** TEST SUCCEEDED **`.

## Implementation (integrated)

- `API/Selection/SelectionDTO.swift` — pinned wire DTOs: `ModelRef`, unknown-safe
  `AgentInfo`/`ModelInfo`, discovery envelopes, and the `SessionSelection` readback subset
  of `Session.Info`. No R04 DTO was modified; readback uses an additive subset decoder.
- `API/Selection/SelectionAPI.swift` — request builders (`agentsRequest`, `modelsRequest`
  with `location[directory]`; `switchAgentRequest` body `{agent}`; `switchModelRequest`
  body `{model: Model.Ref}`; `readSelectionRequest`). Discovery maps `400/401/503` and
  malformed bodies; selection requires `204`, classifies declared `400/401/404` as
  rejections, everything else (5xx, transport, non-204 2xx) as `.unknown`, and performs a
  best-effort readback on the **same** connection after a `204`.
- `State/Selection/SelectionSummary.swift` — `AgentSummary`/`ModelSummary`, `SelectionProblem`,
  discovery/selection states, `SelectionConfirmation`, and the store-facing outcome.
- `State/Selection/SelectionStore.swift` — `@MainActor` Combine store with independent
  `selectedAgent`/`selectedModel`, separate discovery/selection/session-sync/check
  generations, and an active-session guard. `discover()` publishes agent and model results
  independently; `selectAgent`/`selectModel` supersede in-flight work and publish only on
  `.applied`; `activeSessionChanged()` resets prior-session state and best-effort hydrates
  the new session's authoritative selection; `checkSelection()` reconciles `.unknown`
  against the documented read; `isChecking` drives busy UI.
- `App/Composition/SelectionComposition.swift` — one `currentContext` per closure; agent
  and model selection each resolve the connection once and map the adapter result.
- `Features/Selection/SelectionView.swift` — plain, replaceable view: `mode`-filtered agent
  picker, enabled-model picker with provider-qualified labels, truthful discovery/selection
  statuses, retry for retryable rejections, checking indicator, and re-discovery on
  active-location change.
- `App/RootView.swift` / `App/JoycodeApp.swift` — additive composition wiring.
- `Joycode.xcodeproj/project.pbxproj` — new file references, a `Features > Selection` group,
  and app/test target membership; all IDs are 24-char, every group is reachable, and no
  frozen file was edited.

## Review findings and fixes

Two fresh read-only reviews (`change-reviewer`, `ui-spec-reviewer`) examined the draft. The
correctness review found **no High or Medium issues** and confirmed the generation guards,
same-connection readback, conservative error classification, unknown-safe decode, frozen-file
untouched status, and pbxproj membership. The UI review found four Medium findings and Low
notes; all four Mediums were fixed:

1. **Ambiguous model rows on name collision** — model rows now render
   `name (providerID)` while the selection key stays the composite model id.
2. **No explicit retry after a rejection** — retryable `.rejected` states now show a Retry
   control that re-attempts the exact value; non-retryable `.unavailable`/`.noSession`/
   `.noLocation` do not.
3. **Location change did not re-run discovery** — the view now observes
   `ActiveLocationStore.activeLocation?.directory` and re-runs location-scoped discovery.
4. **Session switch cleared selection without hydrating** — `activeSessionChanged()` now
   performs the documented `GET /api/session/{id}` read and hydrates the new session's
   authoritative agent/model; a superseding selection or a failed read fabricates nothing.

Low improvements also applied: disabled Refresh while discovering, disabled pickers while
their mutation is in flight, a checking indicator/disabled Check, and explicit `.idle`
"not loaded" placeholders. A second fresh review pass confirmed the fixes introduced no
High/Medium issue. A final small delta then addressed three remaining Low findings:
location changes re-discover from `ActiveLocationStore.state` (ignoring the transient
`.resolving` nil that previously flashed a spurious "no location"), a failed session
hydration is surfaced truthfully with a retry instead of an ambiguous empty picker, and the
agent/model retry controls have distinct accessibility labels. A third fresh review pass
examined that delta and found no High/Medium/actionable Low findings.

## Acceptance coverage (offline)

Adapter (`SelectionAdapterTests`, 18): request method/path/body and location query
(`testAgentDiscoveryRequestUsesGetAndLocationQuery`,
`testModelDiscoveryRequestUsesGetAndLocationQuery`,
`testDiscoveryRequestsOmitLocationWhenNil`, `testSwitchAgentRequestUsesPostPathAndBody`,
`testSwitchModelRequestUsesPostPathAndModelRefBody`, `testReadSelectionRequestUsesSessionGetPath`);
unknown-safe decode and `Model.Ref` shape
(`testAgentListDecodesPrimaryModeAndToleratesUnknownFields`,
`testAgentListDefaultsMissingOptionalFields`,
`testModelListDecodesEnvelopeAndModelRefShape`, `testMalformedDiscoveryResponseThrows`);
error mapping (`testListAgentsMapsDeclaredErrors`, `testListModelsMaps503ServiceUnavailable`,
`testSelectModelDeclaredRejectionIsRejectedWithoutReadback`,
`testSelectAgentUndeclared500IsUnknownWithoutReadback`,
`testSelectionNon204SuccessIsUnknown`, `testDeclaredSelectionRejectionClassification`);
same-connection readback and non-fabrication
(`testSelectAgentAppliedPerformsSameConnectionReadback`,
`testSelectAgentReadbackFailureStillApplied`).

Store (`SelectionStoreTests`, 28): discovery success/failure/empty/no-location
(`testDiscoverPublishesAgentsAndModels`, `testDiscoveryFailureIsTruthfulAndIndependent`,
`testDiscoveryWithoutLocationFailsTruthfully`, `testDiscoveryEmptyIsLoadedButEmpty`,
`testHiddenAndSubagentAreNotPrimary`); no optimistic success and independent selection
(`testSelectAgentOnlyAppliedAfterBackendAccepts`, `testSelectModelOnlyAppliedAfterBackendAccepts`,
`testAgentSwitchRetainsSelectedModel`, `testModelSwitchRetainsSelectedAgent`);
truthful absent/disallowed handling
(`testSelectAgentRejectedIsTruthful`, `testSelectModelUnknownIsTruthful`,
`testSelectAgentNotDiscoveredIsRejectedWithoutCalling`, `testDisabledModelIsNotSelectable`,
`testSelectAgentWithoutActiveSessionIsRejected`, `testSelectingCurrentAgentIsNoOp`);
generation/session guards
(`testStaleAgentDiscoveryCannotRegressNewerDiscovery`,
`testStaleSelectionResponseCannotRegressNewerSelection`,
`testSelectionNotAppliedToDifferentActiveSession`,
`testLateSelectionWithoutSessionSyncIsDiscarded`,
`testActiveSessionChangeResetsSelection`);
reconciliation and hydration
(`testCheckSelectionReconcilesUnknown`, `testCheckSelectionDifferingReadStaysUnknown`,
`testSessionChangeHydratesAuthoritativeSelection`,
`testSessionChangeReadFailureDoesNotFabricate`,
`testSelectionSupersedesPendingSessionHydration`,
`testRetryAfterRejectionReissuesSelection`, `testCheckSelectionPublishesCheckingState`,
`testSessionHydrationFailureIsSurfacedAndRetryable`).

Live acceptance and TUI agreement remain **open** under D05.

## Checks actually run

Post-implementation, both requested Debug commands were rerun from the repository root:

```sh
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' build
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -only-testing:JoycodeTests test
```

Build tail: `** BUILD SUCCEEDED **`. Test tail: `Executed 200 tests, with 1 test skipped
and 0 failures (0 unexpected)`; `** TEST SUCCEEDED **`. The new `SelectionAdapterTests` (18)
and `SelectionStoreTests` (28) — 46 selection tests — all passed. The post-test client
exit-barrier timeout diagnostic remains distinct from assertions; the command exited `0`.
The worktree remains entirely untracked/uncommitted and no frozen R04a file was modified.

## Remaining gates

- **D03/D04:** full R01/R02 live acceptance remains open; this slice does not alter those owners.
- **D05:** operation-specific sanitized agent/model discovery and selection captures, plus
  native/TUI selection agreement, remain open with separate disposable-context approval.
- **D07:** broader TUI workflow parity is not established by an offline selection slice.
- **D08:** optimized Release tests stay deferred to N14; no Release check is run here.
- Phase 1 remains incomplete; R06 prompt submission follows the settled R05 selection
  interface, and R07 transcript work follows its frozen projection seam.
