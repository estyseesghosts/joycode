# Phase 0 — Foundation and verified V2 contract

[Roadmap and shared rules](README.md) · [Verification](verification-and-coverage.md)

**Entry:** native app/test harness and F02–F09 implementation exist. **Status (2026-10-01): Phase 0 is complete.** F01–F09 harness/contract/mock-fixture gates, the exhaustive source-derived workflow inventory, narrow pinned service-info/event/TUI-Joycode coexistence evidence, reviewed sanitized captures, exact test results, and the user decision to exclude N14 from this phase's final gate are recorded below and in the linked records. This closes F10/P0 without claiming product parity. Later-work rows remain open in [deferred work](deferred-work.md).

**Non-goals:** chat, composer, children, tabs, complete styling, exhaustive API coverage or plugin compatibility. No backend installation/database/config changes merely to plan or scaffold.

## Waves

1. F01 → F02 → F03: decisions and shared contracts first.
2. F04, F05, F06, F07, F08 are independent boundaries after F03; run at most three at once. F06/F07 use the agreed transport interface, not concurrent edits to F04. Any project wiring is integrator-owned.
3. F09 → F10 integrate and verify. If fixtures expose a contract discrepancy, resolve it before dependent work.

### F01 — Pin release and operation evidence · S

- **Outcome/scope:** proposed `docs/v2_contract.md`; pin installed/selected V2 release, schema revision/hash, generated client revision, official source links and minimum initial operation inventory.
- **Inputs/outputs:** official V2 contract → operation/context/error/event evidence ledger and safe fixture-acquisition checklist. Include discovery/ensure/authentication semantics, registration format and version policy. Explicitly mark unknowns.
- **Dependencies:** approved live-test environment and release choice; no code prerequisite.
- **Verify/accept:** each Phase 0/1 operation has provenance, scope, wire schema, error behavior and a way to acquire sanitized fixtures. No old report example substitutes for evidence.
- **Non-goals:** all 136 routes, legacy adapter, service restart, hidden credential inspection or modifying other projects.

### F02 — Native app and test harness · S after F01

- **Outcome/scope:** `App/`, Xcode project/targets, test configuration, `docs/development.md`; create minimum SwiftUI app and focused unit, UI and opt-in live test arrangement.
- **Inputs/outputs:** agreed macOS/Swift/Xcode deployment decision → reproducible launch/build/test harness and documented exact scheme/destination/commands. No commands are presumed by this plan.
- **Verify/accept:** app launches, smoke unit test executes, failure propagates through documented command, live tests are explicitly opt-in. Decide target file membership before independent writers.
- **Non-goals:** network features, bespoke component library, many packages, hand-editing generated outputs.

### F03 — Identity and API/state interfaces · S after F02

- **Outcome/scope:** `Domain/Identity/`, `API/Interfaces/`, `State/Contracts/`; establish IDs, location and service endpoint, mockable API/event/clock/cancellation boundaries.
- **Inputs/outputs:** F01 scoping → distinct connection/project/location/workspace/worktree/session/parent/tab types and feature actions. Agree structured transcript adapter seam without exhaustively modeling future resources.
- **Verify/accept:** tests/examples cannot interchange session/project/tab IDs; scoped request construction is explicit; views receive state/actions, not URLs.
- **Non-goals:** endpoint implementations, giant universal coordinator or domain rewrite of OpenCode runtime.

### F04 — Native HTTP transport · P after F03

- **Outcome/scope:** `API/HTTP/`, focused transport tests; URLSession/Codable async requests, status/error decoding, authentication headers, cancellation, timeout and safe logging.
- **Inputs/outputs:** endpoint/context/request → typed response or distinguishable auth/transport/protocol/backend error.
- **Verify/accept:** mock method/path/body/header checks, non-2xx handling, malformed/unknown response, cancellation and secret redaction. Unsafe redirects cannot leak service credentials to another origin.
- **Non-goals:** JS ordinary requests, every resource adapter, automatic retry of mutating requests.

### F05 — Sanitized fixture support · P after F03

- **Outcome/scope:** `Tests/Fixtures/Core/`, fixture loader and contract-test helpers; provenance-tagged minimal examples, controlled HTTP/event sources.
- **Inputs/outputs:** schema and approved captures → deterministic tests with no secrets, private paths or user prompt content.
- **Verify/accept:** missing/incompatible fixtures fail clearly; actual-vs-synthetic provenance distinguishes contract evidence from constructed edge cases.
- **Non-goals:** fabricated live success or shared fixture files edited by every feature worker.

### F06 — Event-source transport · P after F03

- **Outcome/scope:** `API/Events/`, parser tests; verified framing and AsyncSequence boundary, connection cancellation and failure signaling.
- **Inputs/outputs:** authenticated stream → decoded envelope/unknown-safe event or explicit failure. Agree one-owner consumption interface; creation alone must not unexpectedly spawn multiple readers.
- **Verify/accept:** partial chunks, multi-event frames, Unicode boundaries, malformed/unknown payloads, cancellation and stream close. Bounded parser memory.
- **Non-goals:** assumed replay/event IDs/automatic reconnect; session reducers or rendering.

### F07 — Local service discovery and lifecycle boundary · P after F03 (current slice F07-R)

- **Outcome/scope:** `Service/`, service tests and feasibility note; native passive discovery and compatibility boundary matching supported release behavior. This does not claim F07 is complete.
- **Inputs/outputs:** local installation/registration → healthy authenticated endpoint or clear missing/incompatible/auth/read or probe failure. Evaluate optional helper only if a later approved lifecycle slice needs it and native replication is unnecessarily difficult; document the tradeoff.
- **Verify/accept:** F07-R is implemented as passive, read-only registration discovery and does not call `Service.ensure`. Managed startup is deferred and may be revisited in R01 only as a separately approved policy/lifecycle slice; no startup gate is complete. Startup failure/race proof remains open only if that slice is approved.
- **Non-goals:** editing registration/config/DB, arbitrary remote servers, killing unrelated processes or app-lifetime sidecar assumption.

### F08 — Versioned local presentation storage · P after F03

- **Outcome/scope:** `State/LocalPreferences/`, persistence tests; small atomic local schema and migration/corruption policy.
- **Inputs/outputs:** typed presentation values → versioned safe storage. Later slices extend it sequentially for drafts/tabs/order.
- **Verify/accept:** round-trip, interrupted writes, corrupt/older/newer schema and safe recovery; no credentials or transcript database.
- **Non-goals:** backend session persistence, cloud sync, prematurely implementing every future setting.

### F09 — Diagnostic composition · S after F04/F06/F07

- **Outcome/scope:** integrator owns `App/Composition/` and `Features/Diagnostics/`; wire test doubles/real boundaries to simple connection/version/error/event diagnostic view.
- **Inputs/outputs:** interfaces → disconnected/connecting/connected/incompatible/failure screen. No displayed secrets or unchecked backend data interpreted as instructions.
- **Verify/accept:** harness runs, mock states accessible, app starts without service, no duplicate stream caused by view remount. R01/R02 own real live milestone proof.
- **Non-goals:** chat, final chrome, credentials dumped to UI, broad service control panel.
- **Status:** F09 implementation and testing are done; its focused checks feed the completed F10/P0 Phase 0 gate. Release disposition beyond the unsigned app compile remains deferred to N14 under D08. See [deferred work](deferred-work.md).

### F10 — Workflow inventory and P0 gate · S after F09

- **Outcome/scope:** `docs/parity_inventory.md`, worklog/gate record; map pinned official TUI user actions to evidence, proposed slice, support state and approved alternatives.
- **Inputs/outputs:** actual TUI workflow list, F01 ledger → initial parity scope and P0 evidence; don't equate endpoints with product requirements.
- **Verify/accept:** exact established checks and versions recorded; harness/fixtures/interface gate complete; every identified workflow is inventoried, mapped to an owner and next gate, classified conservatively, and any uncertainty or omission is flagged. Inventory is maintained rather than frozen forever. N14 is not required for this Phase 0 gate; it remains the later whole-product/final parity and release gate.
- **Non-goals:** claiming parity, performing destructive service tests or implementing future features.
- **Status (2026-10-01): complete for Phase 0.** F09 is done. F10-A is exhaustive for the pinned source-derived workflow inventory: rows retain source-only/mock-only/planned/blocked/experimental status where later evidence or decisions are required, with owners and next gates recorded and no silent omissions. The unsigned Release app build passed; optimized Release tests remain explicitly deferred/open to N14 under D08 and were not required for this Phase 0 gate. Focused offline verification was 85 passed, 1 skipped, 0 failed; opt-in live was 1/1; fixture-focused tests were 15 passed. The approved narrow evidence included the pinned `@opencode/cli-darwin-arm64@2.0.20` binary (SHA-256 `e79693d5feeda214883c901d693dc2906b3b6a2cd4d94d41fa4ebad68ffac902`), loopback-only temporary service, authenticated `/api/info` and `/api/event` with first `server.connected`, official TUI coexistence, and two reviewed sanitized fixtures. No provider or session mutation occurred. The first exploratory TUI run showed an external TLS connection; its cause/IP mapping remains unconfirmed, and the final run disabled auto-update and was loopback-only. See [sandbox evidence](p0-v2.0.20-sandbox-2026-10-01.md), [parity inventory](../parity_inventory.md), and [Release validation](release-binary-validation.md). N14 remains the later whole-product/final parity and release gate, not a Phase 0 prerequisite.
