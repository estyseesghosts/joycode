# R08 — Live event fanout, hydration/event reconciliation, tombstones (offline)

Date: 2026-10-05. Status: implemented and verified **offline only**. This is not live acceptance and not Phase 1 completion. R09–R14 are untouched. No existing-service requests, service lifecycle actions, provider calls, backend registration/config/database edits, or commits were made. Optimized Release tests remain deferred (D08/N14).

## Contract basis (source-only evidence)

Pinned OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`; files read: `packages/schema/src/session-event.ts`, `packages/server/src/event-feed.ts`, `packages/server/src/handlers/event.ts`, `packages/core/src/session/projector.ts`, `packages/core/src/session/message-updater.ts`, revert handling. None of this was exercised against a running service.

- `/api/event` is live-only: no replay, no exactly-once, no total order.
- `server.connected` is a bare `data: {}` marker. It carries no generation, version or watermark. The server registers the subscriber queue before emitting it, so after the marker later publications are queued for that subscriber. It is a readiness signal only.
- The per-subscriber queue is a 4096-entry dropping queue; overflow fails the stream. A stream end or failure therefore means events may have been lost.
- History snapshots (`GET /api/session/{id}/message`) carry no sequence comparable to event sequence, so "durable events outrank snapshots" is rejected. Local invalidation epochs plus scoped authoritative resync are used instead.
- Message removal exists only through `session.revert.committed` (deletes the boundary message `data.to` and every later one, inclusive) and `session.deleted`. No legacy `message.part` / `message.removed` event is invented. `session.message.content.updated` is replay-only and not public; if one ever arrives it is treated as history-changing.
- Text/reasoning content has no persisted IDs, so live ordinals are never assumed to equal history indices. Ephemeral deltas and progress are therefore **not applied**.

## Behavior implemented

### Fanout (`State/ConnectionEventOwner/ConnectionEventFanout.swift`)

- `ConnectionEventOwner` still opens exactly one subscription per connection generation and delivers `ConnectionEventSignal` (`.connected`, `.event`, `.failed`, each generation-tagged) through `fanout`.
- `reset(generation:)` runs on context change. `deliver` drops signals for a non-current generation, so a late old stream cannot move readiness.
- `addObserver` replays the current ready/failed phase to late observers, so composition order cannot hide readiness or failure.
- A stream that ends or throws while current delivers `.failed` (`subscriptionFailed` is also set). Observers are never left to infer continuity from silence.

### Classification (`State/SessionProjection/SessionEventRouter.swift`)

A pure `route(EventEnvelope)`: `ignored`, `historyChanged(session)`, `messagesRemoved(session, boundary)`, `sessionDeleted(session)`, `unroutable`. Routing uses only `data.sessionID`; envelope `location`, `durable.seq` and ids are never used to order events. Known no-effect types (status, usage, viewed, rename, inbox bookkeeping, execution start, ephemeral deltas/progress) are ignored. Known history-affecting types and any unknown `session.*` type with a session id invalidate. A `session.*` event whose session cannot be identified is `unroutable` and refreshes the active session. Non-session events are ignored. Tables are in the source for tests.

### Reconciliation (`State/Transcript/TranscriptStore.swift`)

- No event payload is merged into records. Events only invalidate, tombstone, or mark stream state.
- A history-affecting event for the active session bumps a local `invalidationEpoch`. A snapshot remembers the epoch it started under. If events arrived during the fetch the reply is still published (it is at least as recent as the display) but the state is `resyncing`, and one coalesced, debounced follow-up fetch is scheduled (default 150 ms).
- In-flight fetches are never cancelled by events, so a steady stream cannot starve a fetch. An explicit `refresh()` still supersedes (newest request wins by request generation).
- Tombstones are the only event-derived facts kept. `session.revert.committed` drops the boundary message and every later displayed message and remembers the boundary and removed ids (bounded: 32 boundaries, 1024 ids). A snapshot that began before the removal is discarded and refetched. Later snapshots are filtered (truncate at a boundary, drop removed ids). If the boundary is not displayed, the display is kept but marked `resyncing`.
- `session.deleted` for the active session clears the display, cancels work, blocks hydration for that session on that connection, and sets "This session was deleted."
- Events for other sessions or other connection generations are ignored.
- With `awaitsEventStream` (production wiring) the first snapshot starts only after `server.connected`, and readiness itself invalidates any earlier snapshot. Defaults (`awaitsEventStream: false`) keep the R07 snapshot-only behavior.
- Stream failure sets `streamLost` and keeps records. Recovery is R13 and is not implemented.
- `TranscriptSynchronization` states: `unavailable`, `sessionRemoved`, `refreshFailed`, `streamLost`, `awaitingStream`, `hydrating`, `snapshotOnly`, `resyncing`, `live`. `live` requires a ready stream and a published snapshot that began after the last event-known change.

### Presentation and wiring

- `TranscriptView` header shows the sync state ("Live", "Updating", "Loading", "Connecting to live updates…", "Snapshot", "Live updates stopped · Snapshot may be out of date", "Session deleted"). The view owns no observations; composition binds the store (`ConversationComposition.bindTranscriptEvents`) and the store retains the observation.
- `JoycodeApp` production stores and `RootView` convenience init pass the app-owned `ConnectionEventOwner` into `ConversationComposition.transcript`.
- DEBUG offline fixture plays `server.connected` and an `inbox.delivered` event (after the fixture backend accepts a prompt) through the same fanout.

## Verification actually run (Debug, offline)

See the final report for exact counts and log paths. Highlights:

- New unit tests: `SessionEventRouterTests`, `ConnectionEventFanoutTests` (including owner→fanout over a fake event source), `TranscriptReconciliationTests` (event during slow fetch, burst coalescing, superseded reply, ephemeral events, other-session/generation events, unroutable/unknown events, revert truncation/discard/tombstone filtering/boundary not displayed, session deleted, session and connection replacement, stream failure, failed follow-up, readiness gating and invalidation, late-bound observer replay).
- New native UI test `testOfflineFixtureSendUpdatesTranscriptFromEventsWithoutRefresh`.
- Mutation check: disabling the pre-removal-snapshot discard makes `testSnapshotThatBeganBeforeRemovalIsDiscardedAndRefetched` fail; original restored.
- Debug and Release builds.

## Limitations and unresolved assumptions

- No token-level streaming: text/reasoning/tool progress deltas are not applied; content appears at the next durable boundary event's snapshot.
- Drafts and send attempts are in memory only.
- `ComposerStore` converts a `.sending` attempt to `.unknown` on a connection change even if its dispatch Task had not started; over-conservative in a tiny window and unrecoverable until R12 (no re-POST).
- Accepted prompts appear through the event stream (or manual refresh). No composer-to-transcript refresh hint exists, so a lost `session.inbox.delivered` leaves the prompt hidden until another event or Refresh.
- No reconnect or authoritative resync after stream loss (R13); no cursor paging, burst handling or >50-record windows (R14); no unknown-outcome recovery (R12).
- The history-affecting list is source-derived, not observed live. Event payload shapes beyond `data.sessionID` and `session.revert.committed.data.to` are not relied on.
- Whether the history read after `server.connected` includes everything published before the subscriber registered rests on the source-verified registration order; it has not been exercised against a service.
- Event identity/dedup is not used: duplicates are harmless because they only invalidate.

## Approval-gated, not run

- Any live check against an OpenCode service (event stream readiness, revert/delete behavior, queue-overflow failure, rename/projection agreement with TUI).
- Provider-backed prompt/response flows and TUI comparison.
- Optimized Release tests (D08/N14).
