# R04 — Root session create/load slice record (2026-10-01)

[Phase 1](phase-1-single-session.md) · [Verification](verification-and-coverage.md) · [Deferred work](deferred-work.md)

## Scope and outcome

Phase 1 R04 implements root session create/list/get/load with one active session.

- `API/Sessions/` — pinned wire DTOs (`SessionInfo` with `id`/`parentID`/`projectID`/`title`/`location.directory`),
  `SessionAPI` request builders and methods for `GET /api/session`, `GET /api/session/{id}`, `POST /api/session`,
  and a `historyRequest` seam for R07.
- `State/Sessions/` — `SessionSummary`/`SessionPage`, `ActiveSessionState`, and `ActiveSessionStore`
  (`@MainActor`, Combine) with a stable summary, a create-outcome model, and local last-selection retention.
- `Features/Sessions/` — a minimal replaceable `SessionView` (title/location, root rows, Create/Refresh/Check).
- `App/Composition/SessionComposition.swift` plus additive wiring in `JoycodeApp`/`RootView`.
- `LocalPreferencesStore` schema bumped to v2 to persist `lastSessionID` (v0/v1 still readable in memory).

## Contract basis

Verified against the pinned v2.0.20 OpenAPI/generated client before implementation: `POST /api/session` carries an
explicit `location:{directory}` (absent means server cwd, which Joycode never relies on) and returns
`{data: Session.Info}`; `GET /api/session` filters roots with `parentID=null` and returns
`{data:[Session.Info], cursor:{previous?,next?}}`; `GET /api/session/{id}` resolves by id and returns
`404 SessionNotFoundError`. Roots have `parentID` omitted. The pinned server treats a client-supplied `id` as the
identity and returns the existing record if it already exists (verified in core, not an OpenAPI idempotency key),
which is what makes an ambiguous create correlatable.

## Acceptance coverage (offline)

| Acceptance | Evidence |
|---|---|
| Backend may hold multiple roots while the UI presents one | `refreshRoots()` populates `roots` (2+ in tests) with `activeSession == nil`; the view renders selectable root rows and one active session. |
| Load/restart retrieves true title/location | `restore()` reads the persisted `lastSessionID`, `get`s it, and publishes `.loaded` with the server's title/directory (test). |
| Rejected creation does not fabricate success | `.backend(400)`/`.unauthorized`/`.notConnected` → `.creationRejected(...)`, `activeSession == nil` (tests). |
| Ambiguous creation does not fabricate or duplicate | transport failure / malformed body / unexpected status → `.creationUnknown(id)`; create is called exactly once (no auto-retry); a client `ses_…` id is supplied so `recoverUnknownCreation()` can correlate via `GET`. Loads and new creates are mutually excluded while `.creating`/`.creationUnknown` (tests). |
| Local last selection only | only `lastSessionID` is persisted (schema v2); no transcript/conversation storage. |

## Checks actually run

- `xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' build` → BUILD SUCCEEDED.
- `xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -only-testing:JoycodeTests test`
  → **128 executed, 1 skipped, 0 failures**; `SessionStoreTests` 26 passed.

No UI test, live test, provider call, session mutation, service startup, or Release run was performed.

## Open / deferred

- **D05 (live capture):** R04 remains the owner of a live, sanitized session list/create/get capture; this record is
  offline-only and requires separate approval for a disposable pinned context.
- **Create reconciliation:** `recoverUnknownCreation()` performs a minimal verified `GET`; the full unknown-mutation
  policy (including a user-initiated re-create after `clear()`) belongs to R12.
- **Persistence-write failures** remain best-effort (`try?`); surfacing them is deferred.
- **Paging:** `refreshRoots()` keeps only the first page; cursor paging belongs to R14.
- **History hydration:** only the request builder exists; decoding/rendering belongs to R07.
- R01/R02 acceptance gates (D03/D04) are untouched by this slice.
