I re-reviewed the current `main` tree at `2b71b117de5b464882483aacaf447a3f98f2a294`, including the R01–R10 stores, compositions, transcript tests, event ingress, and the pinned OpenCode 2.0.20 source at `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`.

The earlier hardening direction holds, with a few corrections.

## Re-review conclusions

| Earlier suggestion | Result |
|---|---|
| Reuse HTTP sessions | **Confirmed.** Every ordinary API family currently creates its own `URLSessionHTTPTransport`, and each request creates another `URLSession`. Make transport application-scoped. |
| Remove `Data([byte])` in SSE loop | **Confirmed.** This is a real unnecessary allocation on every SSE byte. |
| Reduce RootView observation | **Confirmed.** `RootView` observes nine stores while mostly forwarding references. |
| Remove `SelectionView` session/location observation | **Confirmed bug.** The comment says those properties are no longer observed, but they are still `@ObservedObject`. |
| Replace transcript page rereads with event projection | **Confirmed, but refine the design.** Do not throw away R08's conservative snapshot-race logic. Use event projection only once a stable baseline exists, with targeted/snapshot reconciliation as escape hatches. |
| Decode transcript pages without generic JSON | **Deprioritized.** Once repeated page reads disappear, this is no longer the main hot path. Existing unknown-safe decoding is valuable. |
| Use targeted transcript reads | **Stronger than previously stated.** OpenCode 2.0.20 has `GET /api/session/{sessionID}/message/{messageID}`. Joycode should add it. |
| Execution `durableSeq` issue | **Confirmed.** It records durable events before checking event family/session and can grow with unrelated aggregates. |
| Permission dedupe leak | **Correction:** not a leak; its ID window is already bounded at 256. It still does unnecessary bookkeeping before filtering. |
| Locally merge permission events | **Do not do this.** The current authoritative-list design is correct for the pinned permission semantics. |
| Split `ActiveSessionStore` now | **Not justified.** It is large, but I found no architectural defect worth destabilizing before R11. |
| Rewrite event fanout into a complex router | **Defer.** Single synchronous fanout is fine for R01–R10. Revisit for children/tabs. |
| Fix silent preference failures | **Confirmed.** R03 and R04 currently contain `try?` persistence paths that can make state look durable when it is not. |
| Composer task/map retention | **Confirmed.** Completed `sendTasks` are retained per session and `refreshContext()` republishes unnecessarily. |

The biggest architectural change should therefore be a **three-layer transcript model**:

```text
Authoritative snapshot
        +
Durable live projection
        +
Ephemeral streaming overlay
        ↓
Transcript presentation

          │
          ├─ targeted GET /message/{messageID}
          └─ full page GET only when structurally necessary
```

Crucially, this does **not** assert an ordering relationship between a history snapshot and durable event sequence. The current R08 hydration/invalidation rules remain the safety net.

---

# 10-slice R01–R10 hardening plan

## Slice H01 — Application-owned HTTP transport

### Objective

Eliminate per-request `URLSession` creation while preserving the existing security boundary: no redirects, no implicit retries, no credential persistence, and no cross-request cookie state.

### Production files

**`API/HTTP/HTTPTransport.swift`**

Change `URLSessionHTTPTransport` from a lightweight struct that constructs a session inside `send()` into a session-owning transport.

Recommended shape:

```swift
final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    let timeout: TimeInterval
}
```

Configure the session once:

- ephemeral configuration
- redirects always rejected
- no persistent cookies
- preferably disable cookies entirely
- no shared URL cache
- existing protocol-class injection retained for tests
- request/resource timeout remains explicit
- no retry policy

`RedirectPolicy` no longer needs `initialURL` because `HTTPRedirectPolicy.shouldFollow` always returns `false`.

**`App/JoycodeApp.swift`**

Construct one production transport during application composition and pass it downward.

**`App/Composition/DiagnosticComposition.swift`**  
**`App/Composition/ProjectComposition.swift`**  
**`App/Composition/SessionComposition.swift`**  
**`App/Composition/SelectionComposition.swift`**  
**`App/Composition/ConversationComposition.swift`**

Accept `any HTTPTransport` rather than constructing `URLSessionHTTPTransport()` independently.

This also fixes the particularly wasteful R03 path where every location resolution currently constructs a new transport, which itself constructs a new session when used.

### Tests

**`Tests/HTTPTransportTests.swift`**

Add:

- multiple sequential requests use one session/factory
- two different `ServiceConnection`s still receive their own Authorization header
- credentials from request A never appear on request B
- cookies returned by one request are not propagated
- redirect rejection remains unchanged
- cancellation remains `CancellationError`
- 401/backend mapping remains unchanged

Composition tests should verify every production API receives the injected transport rather than constructing a hidden default.

### Exit gate

H01 passes only when:

- one transport can issue at least 100 sequential synthetic requests without constructing 100 sessions;
- redirect/security/cancellation tests remain green;
- no production composition contains `URLSessionHTTPTransport()` except the application-level composition root;
- Debug unit suite is green.

---

# Slice H02 — Cheap SSE ingestion and bounded diagnostics

### Objective

Remove unnecessary allocation from the hottest network loop and prevent diagnostics from producing full-rate UI publications during event-heavy runs.

### Production files

**`API/Events/SSEParser.swift`**

Add:

```swift
mutating func append(_ byte: UInt8) throws -> [EventEnvelope]
```

Have the existing `append(Data)` call the byte API so there remains one parser implementation.

**`API/Events/URLSessionEventSource.swift`**

Replace:

```swift
parser.append(Data([byte]))
```

with direct byte feeding.

Do **not** replace `AsyncBytes` with a custom `URLSessionDataDelegate` yet. The confirmed defect is the extra one-byte `Data`; chunk transport should wait for profiling.

**`State/ConnectionEventOwner/ConnectionEventOwner.swift`**

Keep fanout delivery immediate.

Separate event-delivery state from human diagnostics. Currently each event changes two `@Published` properties:

```swift
eventCount
latestEventType
```

Prefer one diagnostic snapshot:

```swift
struct ConnectionEventDiagnostics: Equatable {
    var count: Int
    var latestType: String?
    var failed: Bool
}
```

Do not republish it for every event in a large burst. Maintain the exact internal count, but coalesce visible diagnostics. A single scheduled diagnostic flush per event burst is sufficient; stream/failure/context transitions should flush immediately.

The diagnostic machinery must never delay `fanout.deliver`.

### Tests

**`Tests/EventSourceTests.swift`**

Add:

- byte API and Data API produce identical frames;
- fragmented CRLF handling remains correct;
- large single-byte feed parses correctly;
- parser limits remain enforced;
- overflow still fails the stream.

**`Tests/ConnectionEventOwnerTests.swift`**

Add an event storm test showing:

- every event reaches fanout;
- event order is unchanged;
- visible diagnostic publications are substantially fewer than event deliveries;
- stream failure publishes immediately;
- changing generations cancels old diagnostic work.

### Exit gate

For a synthetic 10,000-event input:

- 10,000 events reach the observer;
- no event is reordered or dropped by Joycode;
- there is no `Data([byte])` allocation path;
- diagnostic `objectWillChange` is not emitted 10,000 times;
- bounded-buffer overflow semantics remain unchanged.

---

# Slice H03 — SwiftUI observation ownership

### Objective

Prevent conversation activity from invalidating the entire application view hierarchy.

### Production files

**`App/RootView.swift`**

Remove broad observation from Root:

```swift
@ObservedObject var model
@ObservedObject var eventOwner
...
```

Root does not consume most changing properties. Store them as ordinary references and pass them to feature views. Each feature view remains responsible for observing the store it actually renders.

The intended topology becomes:

```text
JoycodeApp owns stores
       ↓
RootView holds references
       ↓
individual feature view observes its store
```

**`Features/Selection/SelectionView.swift`**

Remove:

```swift
@ObservedObject var sessionStore
@ObservedObject var locationStore
```

They are unused and directly contradict the existing source comment.

Prefer the constructor to become simply:

```swift
SelectionView(store: selectionStore)
```

**`App/RootView.swift`** and fixture call sites update accordingly.

**`App/JoycodeApp.swift`**

I would also make P1 explicitly single-window rather than using an app-scoped store graph underneath `WindowGroup`.

Use one named `Window` until the Phase 3/4 multi-window ownership work is intentionally designed.

### Tests

Update existing UI fixtures and compilation tests.

Add a small observation regression test where practical:

- publishing transcript state must not cause diagnostic/session/selection model accesses as a side effect of Root observation;
- SelectionView construction requires only `SelectionStore`.

This does not need a brittle render-count benchmark; the structural rule can itself be enforced by source/API shape.

### Exit gate

- `RootView` has no `@ObservedObject` declarations for forwarded stores.
- `SelectionView` observes only `SelectionStore`.
- P1 exposes one application window.
- All existing eight offline UI scenarios remain green.
- No feature loses updates because its own view still observes its store.

---

# Slice H04 — R01–R06 local-state durability and lifetime cleanup

### Objective

Remove the remaining cases where Joycode claims or appears to retain state despite failing to persist it, and clean obvious task lifetimes without redesigning the session subsystem.

### Production files

**`State/ActiveLocation/ActiveLocationStore.swift`**

Current:

```swift
if var prefs = try? preferences.load() {
    ...
    try? preferences.save(prefs)
}
```

Replace silent failure with explicit state.

Add something like:

```swift
@Published private(set) var persistenceProblem: LocationPersistenceProblem?
```

Selecting a usable directory can still succeed for the running application, but the UI must say that it could not be retained for restart.

Clearing a directory must similarly surface failure because otherwise the old directory may reappear at next launch.

Also move the default filesystem availability probe away from the main actor if possible. Do not add polling; it remains an explicit select/restore/retry check.

**`Features/ProjectPicker/ProjectPickerView.swift`**

Render the persistence warning and a retry/save-again action if appropriate.

**`State/Sessions/ActiveSessionStore.swift`**

The same problem exists around successful loads/creates:

```swift
try? self.persist(id)
```

Add an explicit persistence warning rather than silently pretending restart restoration is guaranteed.

Do **not** turn a successfully loaded backend session into a failure just because local navigation persistence failed. These are different facts.

**`Features/Sessions/SessionView.swift`**

Surface the warning unobtrusively.

**`State/Connection/ServiceConnectionOwner.swift`**

Release its completed `operation` when the owning generation finishes. Do this generation-safely so an older task cannot clear a newer connection attempt.

No larger connection rewrite is needed.

### Tests

Extend:

- `ProjectPickerTests.swift`
- `SessionStoreTests.swift`
- `LocalPreferencesStoreTests.swift`
- connection owner tests

Test injected write failures for:

- selecting location;
- clearing location;
- loading a session;
- creating a session;
- restoring after failed persistence;
- later successful save clearing the warning.

### Exit gate

- no R03/R04 success path silently uses `try?` for a persistence operation whose failure affects restart behavior;
- backend/runtime state remains usable when only local persistence failed;
- UI distinguishes “active now” from “saved for restart”;
- no completed R01 operation task remains retained indefinitely;
- focused R01/R03/R04 tests pass.

---

# Slice H05 — Single-message transcript read boundary

### Objective

Give R08 a cheap authoritative recovery primitive before changing the live projection model.

This should land independently and leave existing transcript behavior unchanged.

### Production files

**`API/Transcript/TranscriptAPI.swift`**

Add:

```swift
static func messageRequest(
    sessionID: SessionID,
    messageID: String
) -> HTTPRequest
```

for:

```text
GET /api/session/{sessionID}/message/{messageID}
```

and:

```swift
func message(
    connection: ServiceConnection,
    sessionID: SessionID,
    messageID: String
) async throws -> TranscriptMessage
```

Validate that the returned message ID matches the requested ID.

Map 404 distinctly rather than converting it into a generic malformed response.

**`Domain/Transcript/TranscriptMessage.swift`**

Add a single-message envelope decoder reusing the existing message conversion rules.

Do **not** replace the current unknown-safe generic page decoder in this slice.

Unknown/malformed message behavior should remain:

- known valid shape → typed value;
- unknown variant → safe opaque value;
- malformed envelope → API error.

### Tests

**`Tests/TranscriptAPITests.swift`**

Cover:

- exact request path;
- success envelope;
- every currently supported message variant;
- unknown variant;
- malformed envelope;
- wrong returned message ID;
- 400/401/404;
- cancellation.

### Exit gate

H05 passes when Joycode can authoritatively reconcile one message without reading the latest 50, and existing page decoding behavior has not changed.

---

# Slice H06 — Pure transcript live-event decoder and durable reducer

### Objective

Create a side-effect-free reducer for the high-volume assistant execution path before integrating it into `TranscriptStore`.

This is where most correctness risk lives, so keep it completely pure and heavily tested.

### New files

**`State/SessionProjection/SessionTranscriptEventDecoder.swift`**

Decode only source-verified OpenCode 2.0.20 event families into typed Joycode events.

High-priority families:

```text
session.step.started
session.step.streamed
session.step.ended
session.step.failed

session.text.started
session.text.ended

session.reasoning.started
session.reasoning.ended

session.tool.input.started
session.tool.input.ended
session.tool.called
session.tool.success
session.tool.failed
```

Do not interpret unknown fields.

Do not make ephemeral ordinal equal a persisted content-array index.

**`State/Transcript/TranscriptLiveReducer.swift`**

Pure input:

```swift
current transcript projection
+
typed durable event
```

Pure output:

```swift
.applied(...)
.needsMessageRefresh(messageID)
.needsFullRefresh(reason)
.ignored
```

### Important reducer rules

**Step start**

`session.step.started` can create a new assistant row because the event supplies the assistant message ID, agent, model and start time.

If that assistant already exists in a later/completed state, a delayed start must not regress it.

**Tool lifecycle**

Tool ID is stable inside an assistant.

- `tool.input.started` may create the tool because it carries ID and name.
- `tool.input.ended` updates only the matching streaming tool.
- `tool.called` may transition an existing tool to running.
- if `tool.called` arrives without the preceding tool start, it lacks enough information to safely invent the complete tool → request a targeted assistant-message read.
- terminal success/failure updates an existing tool.
- terminal event for an unknown tool → targeted assistant-message read.

A terminal tool state can never regress back to streaming/running.

**Step terminal**

Updates the known assistant only. Missing assistant → targeted message read.

**Duplicate events**

Must be idempotent.

**Malformed recognized events**

Must not partially mutate state. Return reconciliation instead.

**Other-session events**

No mutation.

### Existing files

**`State/SessionProjection/SessionEventRouter.swift`**

Narrow its role.

It should classify structural/fallback events rather than treating every assistant lifecycle event as `historyChanged`.

Keep:

- session deletion;
- revert;
- unknown session events;
- structural rows not covered by the reducer;
- session attribution.

Do not let this file grow into the reducer.

**`Domain/Transcript/TranscriptMessage.swift`**

Add small internal construction/copy helpers if necessary. Avoid exposing wire-format mutability throughout the application.

### Tests

Add **`Tests/TranscriptLiveReducerTests.swift`**.

The tests should be exhaustive over:

- complete tool lifecycle;
- duplicate lifecycle;
- terminal-before-start;
- delayed start after terminal;
- missing assistant;
- missing tool;
- wrong session;
- malformed IDs;
- step failure;
- repeated success;
- multiple tools in one assistant;
- tool output containing large text/file records;
- one bad event does not corrupt valid neighboring content.

### Exit gate

The reducer is accepted only if:

- it performs no I/O;
- it knows nothing about SwiftUI;
- every supported transition is idempotent;
- no event can regress a terminal fact;
- insufficient information always yields reconciliation rather than fabrication;
- all high-volume durable tool lifecycle families have deterministic tests.

---

# Slice H07 — Ephemeral streaming overlay and stable presentation identity

### Objective

Add text/reasoning/tool-input streaming without corrupting the persisted transcript model or causing a SwiftUI publication for every tiny delta.

### New file

**`State/Transcript/TranscriptLiveOverlay.swift`**

This is separate from authoritative `TranscriptMessage`.

Use live-only identities:

```text
text/reasoning: assistantMessageID + ordinal
tool:           assistantMessageID + toolID
```

These are **not** persisted `TranscriptContentID`s.

The overlay exists only while the corresponding live operation is active.

### Behavior

`session.text.started`

Create a live text slot associated with that assistant and ordinal.

`session.text.delta`

Append only to that live slot.

If start was missed, do not guess an array index.

`session.text.ended`

Use the full terminal value as authoritative for that live slot, then settle it into the durable projection where mapping is known.

If the required live slot was never observed, request targeted assistant-message reconciliation.

Apply the same pattern to reasoning.

For tools:

- input delta updates a live input overlay;
- progress updates transient metadata;
- success/failure destroys transient-only state because terminal events are self-contained.

### Publication coalescing

Do not make the previous “page reread on every event” problem become “SwiftUI redraw on every token.”

Internal overlay mutation can occur per event, but schedule at most one pending presentation flush for a short display interval.

Durable terminal events flush immediately.

There must be no repeating idle timer.

Make the scheduler injectable so tests don't rely on wall-clock sleeps.

### `Features/Transcript/TranscriptView.swift`

Replace the current body-time `identifiedMessages` reconstruction with stable model identity supplied by the store/projection.

Avoid:

```swift
ForEach(Array(content.enumerated()), id: \.offset)
```

for live content.

Use stable presentation IDs based on:

- history message ID;
- stable tool ID;
- explicit live overlay ID.

Persisted text/reasoning may continue using snapshot-relative identities where necessary; do not falsely promote ordinal to persisted identity.

### Tests

Add:

- `TranscriptLiveOverlayTests.swift`
- presentation identity tests

Test thousands of deltas in one synthetic burst.

### Exit gate

- ephemeral deltas never trigger history GETs;
- no persisted content identity is derived from live ordinal;
- missing start events do not fabricate content;
- terminal events clear corresponding overlay state;
- no settled execution retains ephemeral overlay objects;
- one burst has at most one outstanding presentation-flush task;
- duplicate or late terminal events are harmless.

---

# Slice H08 — Replace transcript invalidation loop with tiered reconciliation

### Objective

Integrate H05–H07 into `TranscriptStore` while preserving the conservative parts of R08.

This is the key slice.

### Production files

**`State/Transcript/TranscriptStore.swift`**

Keep the existing machinery for:

- session/connection generation;
- `server.connected` readiness;
- stream failure;
- initial hydration;
- request generations;
- tombstones;
- revert;
- session deletion;
- invalidation while a full snapshot is in flight.

Replace the rule:

```text
almost every history event
→ invalidate
→ GET latest 50
```

with:

```text
event
 ↓
typed live reducer
 ├─ applied locally
 ├─ targeted message read
 ├─ structural full reconciliation
 └─ ignored
```

Inject both:

```swift
loadPage(...)
loadMessage(...)
```

### Targeted read coalescing

Maintain a per-message pending refresh set/task table.

If twenty malformed/missing-prerequisite events all refer to `msg_123`, they should result in one outstanding `GET .../message/msg_123`, not twenty.

A targeted response:

- may safely replace an existing row by message ID;
- must still pass connection/session generation checks;
- must not reorder unrelated rows;
- if the message is absent from the current window and its insertion point cannot be established safely, escalate to a page reconciliation rather than invent ordering.

### Initial hydration race

Do **not** simply buffer SSE and replay it over an arbitrary page response.

Current R08's central point remains valid: there is no event sequence comparable with snapshot sequence.

A snapshot begun while known transcript-changing events arrive remains non-current and requires reconciliation.

Once one snapshot completes in a stable event epoch, the live reducer can become the normal path.

### Structural events

Keep conservative treatment for things where local insertion/deletion order is not sufficiently established.

Examples:

- `session.revert.committed` → existing immediate tombstone/truncation + full reconciliation;
- `session.deleted` → existing removal;
- unknown `session.*` → full reconciliation;
- shell/compaction/system-history families not yet covered by H06 → full reconciliation;
- execution terminal idle row may use one terminal reconciliation until its event-derived row construction is separately proven.

That means one verification read at the edge of an execution is acceptable. Constant reads throughout tool execution are not.

### `App/Composition/ConversationComposition.swift`

Inject both transcript page and message readers.

### `Tests/TranscriptReconciliationTests.swift`

Rewrite the tests around the new tiers but retain all existing race cases.

Particularly preserve:

- event during slow snapshot;
- stale old response;
- connection replacement;
- stream failure;
- revert before/after snapshot;
- session deletion;
- unknown event;
- unroutable session event.

Add counters for page reads and single-message reads.

### Critical performance/correctness gate

Synthetic complete execution:

```text
stable initial snapshot
→ step.started
→ text/tool/reasoning lifecycle
→ 100 tool calls
→ thousands of ephemeral deltas/progress events
→ step.ended
```

During the active assistant/tool sequence:

- **0 additional full history-page reads**
- **0 targeted message reads when the complete event sequence was received**
- all tool states and text presented correctly
- no duplicates

Missing-prerequisite scenario:

```text
baseline
→ tool.success without tool.input.started/called
```

must yield:

- one coalesced message GET;
- not one full-page GET per event;
- no fabricated tool.

Unknown structural event may produce one full reconciliation.

### Exit gate

H08 is complete when the old “event burst → repeated latest-50 GET” behavior cannot occur for the normal assistant/tool path.

This is the hard gate I would use before starting R11.

---

# Slice H09 — Execution and permission event bookkeeping

### Objective

Remove unnecessary global-event work from R09/R10 without changing their proven authoritative semantics.

### `State/ExecutionStatus/ExecutionStatusStore.swift`

Current order:

```swift
guard admit(envelope) else { return }
guard trackedEventTypes.contains(envelope.type) else { return }
...
```

Change to:

```text
event-family filter
→ active-session check
→ event-session attribution
→ active-session match
→ dedupe
→ reducer
```

A recognized but unattributable execution event should still trigger reconciliation, as it does now.

Only relevant active-session durable events should enter durable-sequence bookkeeping.

Either:

- reduce `durableSeq` to active-session scope and clear on session replacement; or
- use a small bounded per-aggregate deduplicator.

Do not retain arbitrary aggregate IDs for the whole connection.

**`Features/ExecutionStatus/ExecutionStatusView.swift`**

The store already computes:

- `lastInterruptError`
- `attention`

but the minimal R09 view does not render them.

Render those states. An unknown/lost interrupt reply should not exist only in store internals.

### `State/Permission/PermissionStore.swift`

Reorder exactly the same way:

```text
permission event family
→ session attribution/match
→ event-ID dedupe
→ authoritative pending-list invalidation
```

Do **not** merge `permission.asked` or `permission.replied` into the list.

The current full pending-list reread is correct because one reply can affect more than one pending request and events are not settlement proof.

### Optional shared helper

If doing so removes duplication cleanly, add:

**`State/SessionProjection/BoundedEventDeduplicator.swift`**

Keep it tiny and policy-free. Do not create a generic event framework.

### Tests

**`ExecutionStatusStoreTests.swift`**

Add:

- thousands of unrelated durable events do not affect active-session dedupe;
- unrelated aggregates cannot expand retained execution bookkeeping indefinitely;
- duplicate relevant durable event remains suppressed;
- session replacement clears appropriate tracking;
- attention appears after lost interrupt reply.

**`PermissionStoreTests.swift`**

Important regression:

1. deliver one permission event;
2. deliver >256 unrelated events;
3. deliver duplicate of first permission event.

The unrelated events must no longer evict relevant permission dedupe history or cause another permission read.

### Exit gate

- unrelated application events cause zero R09/R10 reads and zero R09/R10 dedupe inserts;
- execution durable tracking is bounded/current-session scoped;
- permission semantics remain authoritative-read-only;
- lost interrupt feedback is visible;
- existing R09/R10 race suites remain green.

---

# Slice H10 — Composer retention, hardening stress suite, and offline acceptance

### Objective

Finish the remaining R06 lifecycle cleanup and establish deterministic regression gates for the whole hardening pass.

## Composer production changes

**`State/Composer/ComposerStore.swift`**

### Clear completed task handles

Currently `sendTasks[key]` survives completion.

Clear it when the same generation/attempt still owns that key.

Do not let completion of an old attempt clear a newer task.

### Avoid equal publications

`refreshContext()` currently writes:

```swift
context = next
draftText = ...
submission = ...
```

even when values haven't changed.

Guard each publication by equality.

### Narrow selection observation

Stop listening to broad:

```swift
selectionStore.objectWillChange
```

because it fires for catalog loading, unrelated axis progress, etc.

Expose a narrow composer readiness/context signal from `SelectionStore` or have composition derive one from the exact fields needed by `ComposerContext`.

Use `removeDuplicates()` before refreshing Composer.

Keep the synchronous `send()` context refresh. It is a useful defense against a queued publisher update.

### Bound per-session retained state

Before tabs arrive, define the policy explicitly for:

```swift
drafts
submissions
sendGenerations
sendTasks
```

Rules:

- active session retained;
- sending/unknown attempts cannot be silently evicted;
- completed task handles always removed;
- settled empty state can be evicted;
- retained inactive draft count has a fixed bound.

This prevents Phase 3 from inheriting an unbounded dictionary design.

### Tests

Extend **`ComposerStoreTests.swift`**:

- finished task handle released;
- stale attempt cannot clear new handle;
- repeated equal context refresh causes no observable publication;
- unrelated selection catalog updates do not refresh composer;
- active send/unknown state survives cache pressure;
- settled old state is evicted;
- no automatic resend.

---

## Hardening stress tests

Add a dedicated suite such as:

**`Tests/ConversationHardeningTests.swift`**

Use deterministic counters rather than fragile wall-clock performance assertions.

Scenarios:

### Tool-rich transcript

- 50-row baseline
- 100 tools
- thousands of deltas/progress events
- page GET count during active execution = 0
- targeted GET count = 0 with complete events

### Missing event

- omit one prerequisite;
- targeted reconciliation occurs exactly once for that message;
- no fabricated state.

### Unknown structural event

- exactly one full reconciliation;
- store becomes current again.

### Main-actor state

After settlement:

- no live transcript overlays;
- no completed composer tasks;
- bounded event dedupe;
- no pending transcript reconciliation tasks;
- one connection event subscription.

### Large raw output

Include substantial tool text/file metadata so the tests exercise realistic tool-heavy messages, not tiny `"hello"` fixtures.

Do not make elapsed milliseconds an acceptance gate yet. N09 remains the proper measured performance milestone.

---

## Repository/docs cleanup

**Add root `.gitignore`**

At minimum ignore `.DS_Store`.

Remove all currently tracked `.DS_Store` files.

Update:

- `docs/plan/phase-1-single-session.md`
- `docs/plan/r08-live-reconciliation-2026-10-05.md` or add a new hardening record rather than rewriting history
- `docs/plan/verification-and-coverage.md`
- CPU/performance notes as appropriate

Record explicitly:

> R01–R10 implementation hardening passed offline. This does not close R01/R02/R06/R08/R09/R10 live acceptance and does not constitute P1 acceptance.

Every new Swift/test file must be registered in **`Joycode.xcodeproj/project.pbxproj`**. Continue the existing project-file checks for valid plist and unique PBX IDs.

### Final H10 exit gate

With live opt-ins disabled:

1. All focused tests for H01–H10 pass.
2. Entire Debug unit suite passes with no new skips.
3. Entire existing offline UI suite passes.
4. Fresh Debug build succeeds.
5. Fresh optimized Release **build** succeeds.
6. `project.pbxproj` passes lint/ID checks.
7. No tracked `.DS_Store`.
8. Complete tool-rich stress trace causes no transcript-page read storm.
9. All runtime collections introduced by hardening return to their bounded/settled state.
10. No test contacts a real OpenCode service or provider.

Only after this gate would I resume **R11**, followed eventually by R12/R13/R14 and the approval-gated live verification.

## Dependency order

I would execute the slices strictly as:

```text
H01 shared transport
 ↓
H02 SSE ingress
 ↓
H03 observation ownership
 ↓
H04 local durability/lifetimes
 ↓
H05 single-message transcript API
 ↓
H06 durable transcript reducer
 ↓
H07 streaming overlay
 ↓
H08 transcript integration/reconciliation
 ↓
H09 execution + permission bookkeeping
 ↓
H10 composer + whole-pass acceptance
```

The important architectural boundary is H05–H08. **Do not merge those into one implementation task.** H05 establishes the recovery primitive, H06 proves reduction independently, H07 proves ephemeral presentation independently, and only H08 is allowed to alter the existing conservative R08 store. That makes it substantially harder for a performance optimization to accidentally weaken the correctness work you've already done.
