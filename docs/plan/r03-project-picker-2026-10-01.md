# R03 — One project/location picker slice record (2026-10-01)

[Phase 1](phase-1-single-session.md) · [Verification](verification-and-coverage.md) · [Deferred work](deferred-work.md)

## Scope and outcome

Phase 1 R03 implements the native directory picker and verified project/location resolution.

- `API/Location/` — pinned wire DTO `LocationPublicInfo` (`directory`, `project{id, directory, canonical}`)
  and `LocationResolver`, which scopes `GET /api/location` with the explicit deep-object query
  `location[directory]`.
- `State/ActiveLocation/` — `ActiveLocationStore` (`@MainActor`, Combine) and its state machine:
  `empty`, `selected`, `resolving`, `resolved`, `needsRecovery(directory, problem)`.
- `Features/ProjectPicker/` — `ProjectPickerModel`/`ProjectPickerView` using the native
  `.fileImporter` folder picker.
- `App/Composition/ProjectComposition.swift` plus additive wiring in `JoycodeApp`/`RootView`.

The chosen directory is an explicit **location**; the backend `project.id` is a **distinct project
identity**. Neither is a global request default. Future scoped operations use the resolved location
directory explicitly; nothing is auto-injected.

## Contract basis

Verified against the pinned v2.0.20 OpenAPI/generated client before implementation: `GET /api/location`
with optional `location[directory]` returns `Location.PublicInfo`; declared errors `400
InvalidRequestError`/`401 UnauthorizedError`; conditional Basic auth handled by the existing transport.
Linked worktrees of one repository share `project.id` but have a distinct `location.directory`;
`project.canonical` is the main worktree. A nonexistent/non-git directory is **not** a 404 (the backend
synthesizes a project), so moved/inaccessible directories are detected by a local filesystem precheck
(existence, directory type, readability/executability) and rechecked before a result is published.

## Acceptance coverage (offline)

| Acceptance | Evidence |
|---|---|
| Native directory picker | `ProjectPickerView` uses `.fileImporter(allowedContentTypes: [.folder])`; `project-picker*` identifiers. |
| Cancel | `ProjectPickerModel.completeImport(.failure(...))` leaves state unchanged and never resolves (test). |
| Inaccessible / moved directory | `.missing` → `directoryMissing`; `.notADirectory` → `notADirectory`; `.inaccessible` → `directoryInaccessible`; no request sent (tests). |
| Same-project worktree | Same `project.id` with distinct `location.directory`/`canonical` preserved at resolver and store level (tests). |
| Restored invalid selection asks for recovery | `restore()` with a persisted missing directory → `needsRecovery`; no selection → `empty`; valid → `resolved` (tests). |
| Approved location used in actual requests | `LocationResolver` puts `location[directory]` = approved path on the request; asserted at the transport seam and composed to the final URL (tests). |

## Checks actually run

- `xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' build`
  → BUILD SUCCEEDED (Debug).
- `xcodebuild -project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -only-testing:JoycodeTests test`
  → **99 executed, 1 skipped, 0 failures**; `ProjectPickerTests` 13 passed.

No UI test, live test, provider call, session mutation, service startup, or Release run was performed.

## Open / deferred

- **D05 (live capture):** R03 remains the owner of a live, sanitized `GET /api/location` (and
  `GET /api/project`) capture. This record is offline-only and does not close that live gate; it requires
  separate approval for a disposable pinned context.
- **Persistence-write failure:** `ActiveLocationStore.select`/`clear` treat a failed
  `LocalPreferencesStore.save` as best-effort (`try?`). A save failure can leave the UI state and the
  on-disk selection inconsistent; surfacing it is deferred.
- **UI rendering of recovery:** recovery actions are exercised at the store level; automated UI coverage of
  the recovery affordance is not added.
- R01/R02 acceptance gates (D03/D04) are untouched by this slice.
