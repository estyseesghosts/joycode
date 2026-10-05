# R04a — Server-backed session rename slice record (2026-10-04)

[Phase 1](phase-1-single-session.md) · [Verification](verification-and-coverage.md) · [Deferred work](deferred-work.md)

## Scope and evidence boundary

R04a follows R04 and precedes R05 shared-session work. This slice extends the session
update adapter minimally and adds an explicit session rename action; it does not add
project rename, deletion, local title aliases, or optimistic success.

All checks in this slice are offline. No access to the user's service, service startup,
provider calls, or live session mutations is authorized. The earlier disposable R01/R02
approval does not authorize a new live run. TUI agreement requires separate approval
and remains open under D05; R01/R02 gates D03/D04 and Release testing D08 remain open.

The offline implementation, review findings/fixes, and exact verification results are
recorded below. No live, provider, UI-suite, or Release acceptance is claimed.

## Pinned contract verification (before implementation)

The fresh contract researcher verified official tag v2.0.20 resolves to commit
`84c9be93a56304a108f1a22df0c5d62c26d5b6ca` (source evidence only):

- [OpenAPI PATCH operation, lines 1484–1585](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/protocol/openapi.json#L1484-L1585):
  `PATCH /api/session/{sessionID}`, required JSON object, no additional properties;
  `title`, `metadata`, `permissions` all optional and nullable in OpenAPI. No query
  parameters or location field; context resolves from the pinned session.
- [Generated client, lines 686–696](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/client/src/promise/generated/client.ts#L686-L696):
  success is empty **204**, declared errors **400 InvalidRequestError**, **401
  UnauthorizedError**, **404 SessionNotFoundError**. Generated TypeScript inputs omit
  OpenAPI's nullable alternatives; this slice needs only a nonblank string title.
- [Handler, lines 256–278](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/server/src/handlers/session.ts#L256-L278):
  fields are applied only when defined; falsy defined titles invoke title generation,
  not a documented clear-title operation. Rename omits metadata/permissions entirely.
- [GET operation, lines 1363–1429](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/protocol/openapi.json#L1363-L1429):
  same session-pinned context, `200 {data: Session.Info}` gives authoritative read-back.
  A 204 has no title response to decode. Lost replies require read reconciliation,
  not a blind repeat of PATCH; a differing GET alone cannot prove mutation rejection.

Nullable metadata/permissions runtime handling is unresolved in the pinned sources
and is outside this title-only slice. No current-service behavior was inferred.

## Acceptance matrix

| Acceptance | Required evidence |
|---|---|
| Server-confirmed title, not an alias | Pinned PATCH request and authoritative GET; no title preference or optimistic summary. |
| Rejection and lost reply reconcile | Deterministic injected transport/state tests; no automatic PATCH retry. |
| Navigation derives from authoritative summary | Inspect active title and root labels after read-back; stale reads cannot regress the title. |
| Refresh/restart agree | Offline fresh GET and restored selection tests, distinguished from real backend persistence evidence. |
| Official TUI agreement | **Open:** separate approved disposable live check required (D05). |

## Environment

- Xcode 26.6 (17F113), Apple Swift 6.3.3; native macOS app deployment target 26.0.
- Contract pin: OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`.
- Test scope: synthetic/injected offline responses only; no new sanitized live captures.

## Baseline checks

Before implementation, both requested Debug commands were rerun successfully:

```sh
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' build
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -only-testing:JoycodeTests test
```

Build tail: `** BUILD SUCCEEDED **`.
Test tail: `Executed 128 tests, with 1 test skipped and 0 failures (0 unexpected)`;
`** TEST SUCCEEDED **`. A post-test client exit-barrier timeout diagnostic appeared;
the command exited successfully, and it is not a UI-suite pass.

## Implementation (integrated)

- `API/Sessions/SessionAPI.swift` — title-only `PATCH` request builder (`updateTitleRequest`)
  and `updateTitle`, plus `rename(connection:sessionID:title:)` which PATCHes, then performs a
  best-effort `GET` readback on the **same** `ServiceConnection`. Declared rejections
  (`.backend(400)`, `.unauthorized`, `.notFound`) become `.rejected`; every other status,
  transport failure, or non-204 2xx becomes `.unknown`; PATCH 204 with a failed readback becomes
  `.applied(authoritative: nil)`. The PATCH is never retried. Cancellation propagates through the
  readback.
- `App/Composition/SessionComposition.swift` — one `rename` closure resolves
  `connectionOwner.currentContext` exactly once and uses that one context for both the PATCH and
  its confirmation GET; a missing context yields `.rejected(.notConnected, authoritative: nil)`
  without sending a request.
- `State/Sessions/SessionSummary.swift` — `SessionRenameRequest` (session ID + title),
  `SessionRenameState` (`idle`/`inProgress`/`checking`/`rejected`/`unknown`, each carrying the
  request and, where known, the authoritative `serverTitle`), `SessionRenameOutcome`, and a
  `SessionProblem` mapping/label.
- `State/Sessions/ActiveSessionStore.swift` — rename has its own task/generation ownership
  (`renameOperation`/`renameGeneration`) and is never cancelled by reads. `rename` ignores
  blank/unchanged titles and duplicates while in flight, allows retry from `.rejected`/`.unknown`,
  and applies the outcome only when still the owner. `load`/`selectRoot`/`create`/`restore` are
  excluded while a rename is in flight and clear stale `.rejected`/`.unknown` state before a
  session change. `checkRename` reconciles `.unknown` and only clears to `.idle` when the fetched
  title matches the requested title. `refreshRoots` uses an `activeRevision` capture/compare so a
  list started before a newer active-title fact cannot regress it, while a fresh refresh still
  adopts newer server titles (no sticky local lock-in). `clear` cancels and resets rename state.
- `Features/SessionManagement/Rename/SessionRenameView.swift` — status is rendered in normal
  layout (not an overlay); the editor is disabled while busy; `.rejected`/`.unknown` remain
  retryable; the authoritative `serverTitle` is shown only when present; draft syncs on session
  identity and return to `.idle`; status/check controls have accessibility labels and identifiers.
- `Features/Sessions/SessionView.swift` — hosts `SessionRenameView` only when an active session
  exists.
- `Joycode.xcodeproj/project.pbxproj` — new file references and a valid
  `Features > SessionManagement > Rename` group chain; all group child IDs are 24-char and every
  group is reachable.

## Review findings and fixes

Two fresh read-only reviews (`change-reviewer`, `ui-spec-reviewer`) examined the draft and
confirmed the ten pre-identified defects. A fresh implementer fixed them; primary inspection then
found and fixed two further defects (a sticky `activeTitleLocallyMutated` boolean that
permanently hid newer server titles, and an unguarded `restore()`); a final fresh
`change-reviewer` pass found no High/Medium defect and one Low consistency nit, which was fixed.
Key fixes:

1. Rename readback can no longer clobber a session loaded/created after it (`renameGeneration`
   guard plus navigation exclusion).
2. Cancellation no longer leaves `.inProgress`/`.checking` stuck.
3. Only declared 400/401/404 are rejections; 5xx/transport/non-204-2xx are conservative
   `.unknown`.
4. Rejection and lost reply both perform an authoritative readback.
5. `checkRename` clears uncertainty only when the fetched title matches the requested title.
6. Roots reconciliation is server-authoritative without permanently hiding newer titles and
   without regressing a newer confirmed title.
7. PATCH and its confirmation GET share one resolved service context.
8. Tests were rewritten to exercise the real store/adapter paths (retry from rejection,
   navigation/create exclusion, races, clear/late completion, refresh semantics, restart).
9. `project.pbxproj` membership was corrected (previously the `Features` children referenced
   nonexistent 27-char IDs, orphaning the `Sessions`/`SessionManagement` groups).
10. Rename status moved into layout; copy is truthful; retry is available; accessibility improved.

## Acceptance coverage (offline)

| Acceptance | Evidence |
|---|---|
| Server-confirmed title, not an alias | `SessionAPI.rename` sends a title-only PATCH and confirms via GET on the same connection; the store publishes only the authoritative summary (`testRenameTrimsAndSendsNonblankTitle`, `testRenameAppliedPerformsSameConnectionReadback`). |
| Rejection and lost reply reconcile; no auto PATCH retry | `testRenameDeclaredRejectionPerformsReadback`, `testRenameUndeclared500IsUnknown`, `testRenameLostReplyIsUnknownWithReadback`, `testRenameReadbackFailureYieldsNilAuthoritative`, `testDeclaredRejectionPerformsReadbackAndRemainsRetryable`; the adapter issues exactly one PATCH. |
| Navigation derives from authoritative summary; stale reads cannot regress | `testLoadDuringInFlightRenameIsExcluded`, `testCreateDuringInFlightRenameIsExcluded`, `testLateRenameCompletionAfterClearDoesNotPublish`, `testRefreshRootsDoesNotRegressConfirmedRenameTitle`. |
| Refresh/restart agree | `testRefreshRootsAdoptsNewerServerTitleForActiveSession`, `testFreshRefreshAfterRenameAdoptsNewerServerTitle`, `testRestoreLoadsAuthoritativeTitleAfterRename`. |
| Validation and preference preservation | `testRenameRejectsBlankAndUnchangedTitleWithoutCalling`, `testRenamePreservesPersistedSelection`. |
| Unknown reconciliation | `testCheckRenameMatchingTitleClears`, `testCheckRenameDifferingTitleStaysQualified`, `testLostReplyWithMatchingReadbackClears`, `testLostReplyWithDifferingReadbackStaysQualifiedUnknown`. |
| Official TUI agreement | **Open:** separate approved disposable live check required (D05). |

## Checks actually run

Post-implementation, both requested Debug commands were rerun on the frozen artifact from the
repository root:

```sh
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' build
xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -only-testing:JoycodeTests test
```

Build tail: `** BUILD SUCCEEDED **`.
Test tail: `Executed 154 tests, with 1 test skipped and 0 failures (0 unexpected)`;
`** TEST SUCCEEDED **`. The new `SessionRenameAdapterTests` (8) and `SessionRenameStoreTests`
(18) — 26 rename tests — all passed. The post-test client exit-barrier timeout diagnostic
appeared again; the command exited `0`, it is not an assertion failure, and it is not a UI-suite
pass. `git diff --check` is clean; the worktree remains entirely untracked/uncommitted.

## Remaining gates

- **D03/D04:** full R01/R02 live acceptance remains open; this slice does not alter those owners.
- **D05:** operation-specific sanitized update/get captures, real refresh/restart persistence,
  and native/TUI title agreement remain open, with separate disposable-context approval required.
- **D07:** broader TUI workflow parity is not established by an offline rename slice.
- **D08:** optimized Release tests stay deferred to N14; no Release check is run here.
- Phase 1 remains incomplete; R05 discovery-backed agent/model selection is next in the
  R04 → R04a → R05 wave. R07 transcript work follows its frozen projection seam; prompt,
  blockers, interrupt, synchronization, and P1 integration/live gates still follow.
