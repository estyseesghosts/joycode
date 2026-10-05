# R10 — Pending permissions (offline)

Date: 2026-10-05. Status: R10 implemented and verified **offline only**. No Phase 1 acceptance. No existing-service requests, service lifecycle actions, provider calls, backend registration/config/database edits, commits, or optimized Release tests are authorized or used in this checkpoint.

> **IMPORTANT — All future live model testing must use `openrouter/openrouter/free` only; NEVER Anthropic or OpenAI.** Provider `openrouter`, model `openrouter/free`; no fallback. This user policy does not authorize live testing. The Debug checks here use mocked transports/in-memory fixtures; Anthropic/OpenAI names in synthetic catalogs are labels only, not actual provider calls. See [verification policy](verification-and-coverage.md).

## Source-only contract evidence

Contract pin: OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`. Primary re-read pinned `packages/schema/src/permission.ts`, `packages/protocol/src/groups/session.ts`, `packages/protocol/src/groups/permission.ts`, and `packages/protocol/openapi.json` (raw source only).

- The permission endpoint declarations are in protocol `groups/permission.ts`, not `groups/session.ts`: GET `/api/session/{sessionID}/permission` returns `200 {data: Permission.Request[]}`; GET `.../permission/{requestID}` returns `200 {data: Permission.Request}`; POST `.../reply` takes required `decision` and optional `message`, returning 204 with no content. All three declare 400/401/404. Permission reply does **not** declare 409.
- Request required fields are `id` (`^per`), `sessionID` (`^ses`), `action` (string), `resources` (string array). Optional fields: `save` (string array), `metadata` (object), `source` (`{type:"tool",messageID:string,id:string}`), and `message` (string). Reply choices are `once|always|reject`.
- **Preparation-note correction:** `permission.asked` uses `schema: Request.fields`, which includes required `id`; it does not omit ID at this pin. `permission.replied` carries `{sessionID,requestID,reply}`. Both are ephemeral. Missing/empty identity remains safely unattributable: invalidate/reread, never answer an anonymous event.
- `packages/server/src/handlers/permission.ts` checks ownership for single reads and replies; a missing or wrong-session request returns `PermissionNotFoundError`. The list resolves the session's instance and reads `forSession`. This confirms that 404 is not an intended-reply success signal.

Primary re-read `packages/core/src/permission.ts` from the pinned raw source: requests are held in a process-owned pending map; `list` and `forSession` return pending requests, and `get` returns only a pending entry. Reply publishes before deletion. Reject fails/removes the selected request and every remaining same-session request. Therefore an event cannot substitute for an authoritative list read, and the whole list must be reread after a reply. `always` can save rules and resolve other requests; P1 deliberately does not expose it. No positive settled-detail endpoint remains.

## Adapter safety

Reads require exactly HTTP 200 and a `data` envelope; replies require exactly HTTP 204 with an empty body. A synthetic 204 carrying content is malformed/unknown, never retried. Each operation dispatches once, with no retry. A missing request or HTTP 404 does not establish that the intended reply succeeded. P1 exposes only once and reject, not permanent autoapproval.

400/401/404 are mapped as declared; undeclared 409, other unexpected statuses, transport failures and malformed success responses remain unknown at the composition boundary. Cancellation never proves rejection. A mixed-session or malformed list fails the whole read rather than silently dropping an approval. Unknown metadata is preserved opaquely and extra fields tolerated; debug descriptions redact request payloads. The adapter also conservatively rejects empty action or empty tool-source identifiers, although those fields are plain strings in the pinned schema. This stricter presentation-safety choice surfaces a malformed read, not an invented permission choice.

## Behavior and provenance

The pending list is an authoritative read-owned fact, separate from execution membership and outcome. Permission events invalidate the list; they do not fabricate request insertion, removal or settlement. Local read epochs are not server sequence numbers or snapshot watermarks.

| Fact / action | Owner / source | Safety boundary |
|---|---|---|
| Pending membership | Session-scoped GET list | No optimistic insertion/removal from events or replies; absence is a current read, not proof of reply causation |
| Request identity | Required request ID and session ID | No anonymous approval; unattributable events invalidate and reread |
| Read provenance | Active session + connection generation + local read epoch | No cross-context adoption or comparison to durable server sequence |
| Asked/replied events | Composition-owned fanout observer | Invalidation only; other sessions/generations ignored |
| Reply progress | Local per-request lifecycle | One dispatch per eligible click; duplicates suppressed; no automatic retry |
| Lost reply / 404 | Honest local outcome notice + list reread | Neither implies intended success; no settled-detail recovery claim |
| Stream loss / failed read | Staleness and failure presentation | Prior facts retained, never silently interpreted as empty or settled |
| Execution status | Existing separate R09 store | Pending permission does not rewrite execution membership/outcome |

`PermissionStore` retains composition-owned `eventObservation` and `contextSubscriptions`. Context replacement cancels read/reply tasks, clears per-context facts, and uses a local context epoch to reject old replies even after A→B→A. Button eligibility checks list provenance against the current session/generation before dispatch; the synchronous reply entry point also checks context changes before accepting a tap. Request identities deduplicate within each list, and a bounded 256-event-ID window suppresses repeated invalidations without using durable `seq`.

A reply supersedes any read that started before the reply returned. Only its new authoritative read can release accepted-awaiting-read suppression; a pre-reply read cannot re-enable a duplicate POST. Unknown replies remain ambiguous even after list absence, and are never re-POSTed. Per-request progress/ambiguity is published independently, so an overlapping read cannot hide a reply-state change from the view. Read failure and stream failure retain facts with stale presentation and disable approval.

The minimal permission row renders action/resources/session/request identity, optional message, Allow once/Reject, refresh, progress, stale state and failure/unknown notices. Unknown notices remain visible after the list becomes empty. An unavailable or stale empty list is not presented as "No pending permissions." Execution membership/outcome remains untouched. The DEBUG fixture uses only in-memory requests/replies and source-shaped asked/replied events through the same fanout; it is not provider evidence.

## Integration review corrections

- Corrected the earlier claim that the asked declaration omitted request ID, and the adapter comment's ID pattern (`^per`, not `^per_`).
- Fixed malformed JSON in the API test's optional-message fixture and a composition test's actor access inside an XCTest autoclosure.
- Closed context-publisher-hop and pre-reply-read races; validated attributable requests even from injected list loaders; stale reads cannot authorize replies.
- Published per-request reply sets and kept old-context task completion from erasing a new-context task handle.
- Added focused tests for malformed single-read success, undeclared 409 classification, anonymous injected requests, context changes before publisher delivery, and a read already in flight when the reply returns.

Fresh read-only adapter/project review found no actionable contract or registration defect. A separate store-review delegate returned no text, so it supplied no review evidence. Primary inspected the registered IDs, all changed source/tests and the store races directly, applied the corrections above, and verified them with integrated tests rather than relying on delegate checks.

## Verification record

Debug tests and separate Debug/Release builds only; both live-test opt-ins are unset. Logs are retained under `/private/var/folders/dg/dztwhk5n6rb9xr8jt3t0nkf00000gp/T/opencode/`.

All `xcodebuild` checks use `-project Joycode.xcodeproj -scheme Joycode -destination 'platform=macOS' -derivedDataPath '/private/var/folders/dg/dztwhk5n6rb9xr8jt3t0nkf00000gp/T/opencode/joycode-hardening-derived'`. Tests additionally use `env -u JOYCODE_ENABLE_LIVE_TESTS -u TEST_RUNNER_JOYCODE_ENABLE_LIVE_TESTS` and `-configuration Debug`.

| Check | Scope | Result | Log |
|---|---|---|---|
| Focused unit tests (final source) | `-only-testing:JoycodeTests/PermissionAPITests -only-testing:JoycodeTests/PermissionStoreTests -only-testing:JoycodeTests/PermissionCompositionTests test` | **60 executed** (23 API, 32 store, 5 composition), 0 failures, exit 0 | `joycode-r10-focused-unit-final.log` |
| New native offline UI test | `-only-testing:JoycodeUITests/JoycodeUITests/testOfflineFixturePermissionAllowOnceClearsPendingRequest test` | **1 passed**, 0 failures, exit 0; also passed in final full suite | `joycode-r10-ui-permission.log` |
| Full Debug regression (final source) | `-configuration Debug test` | **537 unit executed, 1 live skip, 0 failures; 8 UI, 0 failures**, exit 0 | `joycode-r10-default-debug-final-2.log` |
| Debug build | `-configuration Debug build` | `BUILD SUCCEEDED`, exit 0 | `joycode-r10-debug-build.log` |
| Release build (no tests) | `-configuration Release build` | `BUILD SUCCEEDED`, exit 0; distinct Release products, `-O -DRELEASE`, arm64/x86_64 | `joycode-r10-release-build.log` |
| pbxproj lint / object IDs | `plutil -lint` + definition scan | OK; **235 definitions, 235 unique, no duplicates**; new build/reference IDs suffix 25–30 | — |
| Swift parse | `swiftc -parse` on all 11 changed Swift files | exit 0 | — |

The first primary focused attempt (`joycode-r10-focused-unit.log`) failed to compile a composition test because `await` appeared inside an XCTest autoclosure; no tests ran. The second attempt (`joycode-r10-focused-unit-2.log`) passed 59 tests, zero failures. One further adapter test enforces the no-content reply contract; the final 60-test result above re-verifies it. Delegate-only checks do not substitute for primary verification.

The first full Debug attempt (`joycode-r10-default-debug-full.log`, before the final no-content reply test) completed **536 unit tests, one live skip, zero unit failures**. During UI execution, XCTest reported other desktop applications as interrupting elements and `testOfflineFixtureRootSelectionUpdatesScope` raised `Can't do regex matching on object 4. (NSInvalidArgumentException)` in its interruption-monitor path. The command then exceeded its 120-second limit before the UI suite completed. This is a failed/incomplete full-suite attempt, not accepted regression evidence; no user windows were closed or unrelated tests changed. Final rerun uses a 600-second command timeout.

The next full attempt (`joycode-r10-default-debug-final.log`) completed **537 unit tests, one live skip, zero unit failures**, and **8 UI tests with 2 failures** (exit 65): interrupt fixture could not find a hit point for the editor's ScrollView; the permission fixture raised the same XCTest interruption-monitor regex exception. The independently focused permission UI test passed, but this full-suite attempt is not green. No cause is inferred from these automation errors; the final repeat preserves the same source and a longer command timeout.

The final same-source repeat (`joycode-r10-default-debug-final-2.log`) passed **537 unit tests with one live skip and zero failures, plus 8 UI tests with zero failures**, exit 0. Earlier UI automation failures remain recorded; no unrelated test was changed to obtain this result. The known pre-existing `EventSourceTests.testEventSourceFailsWhenBoundedBufferDropsAnEvent` multiple-fulfillment flake did not recur in the primary runs.

## Limitations and remaining gates

No real blocked-tool permission demonstration, live list/event timing, runtime auth/error behavior, multi-client/TUI settlement, provider-backed form/question blockers, unknown-outcome recovery (R12), reconnect/resync (R13), or paging/burst acceptance (R14). Offline fixtures are not provider evidence. R11–R14 remain unfinished and P1 is not accepted.

Reply progress and lost-reply notices are in-memory and context-scoped, cleared on session/generation replacement as required by this store's boundary. This is not persistent mutation reconciliation. A successful current reread can make a still-pending request explicitly actionable again after a declared rejection or accepted reply; it never automatically submits again. Unknown replies remain suppressed within the current context even if the list still contains the request. No saved-policy editor or optional rejection-feedback UI is added; the adapter supports the contract's optional message but this UI sends none. Stream failure remains stale even after manual reread; reconnect recovery is not implemented here.

Carried over: no token deltas; drafts and attempts are in memory; composer connection-change ambiguity and lost delivery-event visibility gap remain; no reconnect/resync or paging/burst acceptance. No optimized Release tests were run.

## Next task — CPU investigation before R11

User reports high application CPU usage. **Do not start R11 yet.** After R10, investigate Debug/test tooling overhead versus actual application logic; fix confirmed application-logic defects before R11. No CPU diagnosis or performance acceptance is claimed by this R10 work. Start with offline/disconnected and DEBUG-fixture measurements, identify the exact process/build/scenario, compare a separate Release app build if needed (not optimized Release tests), and preserve the existing service/provider approval boundary. All future live model testing remains restricted to `openrouter/openrouter/free`, never Anthropic/OpenAI.
