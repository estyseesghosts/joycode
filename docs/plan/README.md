# Joycode implementation roadmap

Status: roadmap and status notes, 2026-10-05. See [deferred work](deferred-work.md) for the canonical open-item ledger, [Release validation](release-binary-validation.md) for the F10 Release results and N14 follow-up, and [verification](verification-and-coverage.md) for the evidence boundary.

## Read this first

Joycode will be a native macOS OpenCode V2 client in Swift, principally SwiftUI, with AppKit for window behavior and native text/terminal integration where justified. Build a useful client before polishing it, but build around the intended UI from the outset. Temporary views must have replaceable presentation boundaries, not become a conventional shell that later requires an architectural rewrite.

The repository now contains a native Swift/Xcode app, app/unit/UI test targets, and established Debug checks; F02–F09 implementation exists and Phase 0/F10 was recorded complete on 2026-10-01. Phase 1 is in progress: R01/R02 owner code exists with full acceptance gates still open (D03/D04), and R03/R04/R04a/R05 have offline implementation coverage. F07 app-managed startup remains deferred. Preserve unrelated files and do not commit unless requested.

## Phase map and reading order

| Phase | Deliverable | Plan |
|---|---|---|
| 0 | Verified contract, native harness, diagnostic foundation | [Foundation](phase-0-foundation.md) |
| 1 | Single root OpenCode thread, skeleton UI | [Single session](phase-1-single-session.md) |
| 2 | Single root with subagents, skeleton UI | [Children](phase-2-children.md) |
| 3 | Multiple root threads with tabs, skeleton UI | [Tabs](phase-3-tabs.md) |
| 4 | Multiple threads grouped by project, skeleton UI | [Projects](phase-4-projects.md) |
| 5 | Same functional multi-project app, complete visual design | [Design](phase-5-design.md) |
| 6A | Advanced composer/input | [Input](phase-6a-input.md) |
| 6B | Rich conversation and server-backed session operations | [Conversation](phase-6b-conversation.md) |
| 6C | Project files, review, search and worktrees | [Project review](phase-6c-project-review.md) |
| 6D | Models, connections, credentials, MCP and configuration | [Connections](phase-6d-connections.md) |
| 6E | Shell jobs, interactive terminals and runtime status | [Runtime](phase-6e-runtime.md) |
| 6F | Evidence-backed plugin interoperability | [Plugins](phase-6f-plugins.md) |
| 6G | Native completion, reliability and distribution | [Native/release](phase-6g-native-release.md) |

[Verification and coverage](verification-and-coverage.md) owns the cross-phase gate checklist, design chapter coverage and parity criteria. Read the relevant phase and this index together before assigning a slice.

Phases 0–5 are sequential **milestone gates**, not single assignments. Phase 6 families may run in independent waves after their contracts are settled; their alphabetical listing is not a requirement to finish every family before starting another. Every phase preserves all accepted earlier behavior.

## Sources and conflict decisions

1. Current user requirements govern product order and scope.
2. The official contract of the pinned OpenCode V2 release governs wire behavior. A product requirement cannot manufacture an unavailable backend operation: record a blocker and decide an alternative.
3. [Client design](../opencode_client_design.md) governs visual/interaction intent.
4. [Client architecture](../opencode_client_architecture.md) governs architectural intent and incremental delivery. Its statement that layout is unspecified is superseded by the detailed design.
5. [Images 01–06](../01.png) illustrate the design; prose acceptance criteria resolve conflicts. In particular, image 04 must not justify an opaque surrounding shell or inset composer.
6. [Server report](../opencode_server_architecture.md) is historical context, not an implementation contract. It mixes API generations, package names, message schemas and service lifetimes and ends mid-description.

Official starting points, reviewed for planning on 2026-09-30:

- <https://opencode.ai/v2/docs/build/client>
- <https://opencode.ai/v2/docs/api>
- <https://opencode.ai/v2/openapi.json>
- <https://opencode.ai/v2/docs/troubleshooting>

Use V2 only; do not add legacy/hybrid protocol detection merely because the historical report describes it. Do not infer endpoints, payloads, event names, ordering guarantees or an old `Part` enum. Record release, schema hash/revision, generated-client version and operation-level evidence before implementing each resource family.

Current documentation describes a shared service. Joycode currently uses only F07-R passive, read-only registration discovery; the user-deferred app-managed process startup policy means the client must not call `Service.ensure` implicitly. Revisit startup explicitly in R01. Do not assume port 4096, start a separate daemon for every thread, or stop a shared service on window close/app quit. The documented registration path is `~/.local/state/opencode/service.json`; its pinned format is verified in [v2_contract.md](../v2_contract.md). A sanitized real registration was inspected during the off-pin `2.0.21` read-only check, documented in [the live-check record](live-check-2026-10-01.md); this does not provide the pinned-version evidence still required. Never repair connectivity by editing/deleting registration, configuration or the backend database. CLI API calls may start the service and are not necessarily passive diagnostics. See [deferred work](deferred-work.md).

## Architecture that makes the final UI replaceable

Intended flow: **SwiftUI → feature actions/application state → native API boundary → existing OpenCode service**.

| Proposed area | Responsibility |
|---|---|
| `App/` | Entry point, composition, native windows, target configuration |
| `Service/` | Passive discovery, endpoint authentication, compatible connection; separately approved lifecycle management only if later adopted |
| `API/` | URLSession requests, DTOs/adapters, HTTP/event/WebSocket transport |
| `Domain/` | Distinct identities, context and stable presentation projections |
| `State/` | Session stores, synchronization, navigation, attention, local preferences |
| `Features/` | Small feature views and presentation/action adapters |
| `Tests/` | Contract fixtures, deterministic unit/state tests, UI and opt-in live tests |

Start with a small native app project; module names need not become separate packages. Foundation, Codable, Swift concurrency and Observation are defaults subject to the deployment target decision. A JavaScript helper is a fallback only for difficult verified service-management behavior, isolated from ordinary requests. Do not embed a JS runtime merely to call HTTP.

### Identity and authority

- A **thread** is a root backend session. A **child** is another backend session with a verified relationship, not just any delegated tool invocation.
- A **tab** is a local view of a session. A session can exist without a tab. Initially propose one tab per session; additional views need an explicit decision.
- Connection identity, backend project ID, directory/location, optional workspace, worktree identity, session ID, tab ID and optional window ID are distinct types.
- Context is an explicit immutable argument to each scoped operation, or resolved from a server-pinned session where documented. No mutable global working directory.
- Server session/message persistence, tools, agents, permissions, forms and execution remain authoritative. Local storage contains only versioned drafts/navigation/view preferences/review annotations; it is not a second conversation database.
- Close tab means local close. Hide/collapse project means local navigation change. Neither interrupts nor deletes backend work. Delete, interrupt, move and backend rename are separate explicit actions.
- Project display alias and local reorder are not server project rename or session transfer. Child activity normally stays inside the workframe, not automatically in outer tabs.

### State and event lifetime

Session stores live outside SwiftUI view lifetime. One subscription owner per service connection routes events to all relevant stores; no subscriber per tab/window/card. Views never build requests or decide backend permission policy.

Reconciliation is a first-class contract: establish the subscription, buffer during scoped snapshots, track request/refresh generations, merge using verified identities/semantics, retain deletion tombstones across overlapping pages, and refetch on unknown/unrouteable updates. No assumed global event order, replay or exactly-once guarantee. Bounded buffers and overflow explicitly mark state stale and trigger resync instead of silently dropping correctness-critical updates. Slow rendering must not block transport indefinitely.

Late fetches cannot overwrite newer live state or a different selected context. Missing events on reconnect require authoritative reads of history, execution, permissions, forms and relevant hierarchy. Mutations have pending/confirmed/rejected/**unknown** outcomes. A dropped response after acceptance never authorizes blind prompt retry. If available identifiers cannot prove outcome, show honest ambiguity and an explicit manual recovery path.

Pending permissions and forms/questions are part of the first useful client. Another client may settle them; refetch and remove settled items rather than continuing to offer stale approval. Never workaround missing UI with permanent autoapproval.

### Final UI expectations from day one

Maintain navigation, workframe content, composer and window configuration as separate seams even in plain views. There is one shared workframe, stable selection/draft/focus/scroll across layout changes, independent child activity, and local navigation projected for both layouts. Phase 5 completes one transparent NSWindow with floating controls, horizontal compact navigation, vertically grouped detailed navigation, and the separate attachment–input–send row below the frame.

Final components may be developed in isolated previews once stable input/action contracts exist. Default: start this lane at Phase 5. Earlier preview work is optional only after the relevant feature gates, cannot touch shared state/coordinators, and cannot delay functional gates. Fixture visual acceptance is distinct from live feature acceptance; future controls are absent or explicitly disabled in production until backed by real behavior.

## Assignments and parallelism

Every slice is one bounded assignment to one fresh implementer. Supply goal, owned files/tests, dependencies, pinned contract, checks, acceptance and non-goals. A `P` label means eligible to overlap **after** contracts freeze, not permission to edit shared files concurrently. An `S` label means sequential. Limit a wave to two or three workers by default; additional workers require demonstrably disjoint scopes.

One integrator owns Xcode target membership, composition, global contracts, token changes and gate records. Feature tests/fixtures have feature-specific ownership. If two proposed slices both require central dispatcher/persistence changes, sequence them or give a separate integration slice the shared edits. Review fixes stay with the slice owner while active; completed agents are not reused for unrelated work. Inspect diffs and rerun established checks; summaries are not proof.

Each phase file lists waves. Do not stack later features on a failed phase gate. Investigate failed assumptions rather than accumulating workarounds. Advance feature contracts only when needed; don't research every endpoint before the first usable application.

## Decisions ledger: proposals are not approvals

| Decision | Proposed direction | Gate |
|---|---|---|
| OpenCode release/schema and approved live test project | Pin one known-working V2 release; isolated disposable project, no user-data mutation | F01 |
| macOS, Swift/Xcode and app project setup | Native Xcode app and tests; exact minimum target requires agreement | F02 |
| Connection scope | Local shared service first; remote requires separate TLS/trust/secret threat-model branch | F07, N08 |
| Service helper | Native first; isolated helper only with feasibility evidence | F07 |
| Agent/model defaults | Server-discovered Build/Plan if available; truthful fallback if absent | R05 |
| Project close/rename and session deletion | Local hide/alias; separate confirmed server operations | T07, J02 |
| Layout override/traffic lights | Automatic plus manual override; retain native controls where feasible | V02, V10 |
| Attachments/comments/tasks | Typed verified payloads; local review notes unless backend supports sharing; no invented todo service | A01, C06, V17 |
| Experimental transfer/config/persistent PTY | Explicit approval and release-specific verification, not silently mandatory | B08, D10, E06 |
| Plugin compatibility | Proven subset or approved exclusion; no arbitrary JSX promise | X02–X03 |
| Multiple windows | Optional explicit decision; if accepted, bounded state/lifecycle slices | N02–N04 |
| Notifications/draft privacy/shortcut behavior | Opt-in notifications; scoped local drafts; no text-editing conflicts | N01, N05–N07 |
| Performance and distribution | Measured scenarios and agreed budgets; decide channel, identity, sandbox/update approach | N09–N13 |
| Completeness and exclusions | Maintained official-TUI user-workflow inventory with user-approved dispositions | F10, N14 |

“Complete” means every agreed TUI user workflow is supported and verified, or has an explicitly approved alternative/exclusion. It does not mean all API operations, every future release, or unmodified arbitrary terminal plugins. Backend gaps must remain visible until resolved or approved; never quietly redefine completeness.

## Phase 0 gate result and next bounded work

Phase 0/F10 was recorded complete on 2026-10-01 after the user explicitly excluded N14
as this phase's final gate. The pinned sandbox record documents binary provenance,
`/api/info`, SSE, the narrow Joycode/TUI coexistence run and sanitized fixtures. This is
not broad parity and does not close the full R01/R02 feature acceptance criteria. Phase 1
starts with R01 then R02; keep passive discovery and no app-managed startup unless a
separate policy is approved. Do not assign “build the app, connect, implement chat, and
finish the design” to one worker. See [Phase 1](phase-1-single-session.md) and [deferred
work](deferred-work.md).

Prior Debug baseline: 84 unit cases (83 passed, one opt-in live skip), one UI smoke test
passed, and Debug app build passed. Current focused offline verification is 199 passed,
one skipped, zero failures (200 executed; 14 R03 ProjectPickerTests, 26 R04 SessionStoreTests,
26 R04a SessionRename tests, and 46 R05 Selection tests);
the opt-in pinned sandbox test passed 1/1; fixture-focused tests passed 15. The last audit's default Debug suite passed (201 executed, 200 passed, one live skip, zero failures), including the launch UI smoke test; earlier runner timeouts did not reproduce. These are historical baseline counts, not verification of subsequent changes. The Release-requested build compiled but resolved to Debug, so it was not a validated separate Release artifact;
Release tests remain deferred to N14 after the known testability compile failure (D08).
The earlier off-pin `2.0.21` probe remains separately recorded in [the live-check
note](live-check-2026-10-01.md). Provider and distribution gates are not complete. Record
subsequent gates in the [verification plan](verification-and-coverage.md).
