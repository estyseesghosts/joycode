# Phase 1 — One functional root thread, skeleton UI

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** Phase 0 complete (2026-10-01). **Exit P1:** choose an approved repository, create/reopen/rename one root session, select discovered Build/Plan and model, send text, follow structured tools/output, answer permissions **and forms/questions**, interrupt, quit/reopen and recover authoritative state with TUI interoperability. Live evidence and provider approvals remain prerequisites; see [deferred work](deferred-work.md).

Use plain views with separate navigation, central workframe content and detached composer boundaries. No polished transparent chrome required yet. **Non-goals:** children UI, tabs, multi-project UI, attachments, steering/queues, permanent autoapproval.

## Waves

R01 → R02 establishes real connection/event checkpoint. R03 → R04 freezes session identity/actions. R05 and R07 may overlap on separate selection/transcript areas; R04a sequences with shared session adapter work. R06 follows selection contract. R08 settles synchronization before R09/R10/R11. R10/R11 may overlap only with disjoint stores and a frozen pending-input interface. R12–R14 sequentially integrate correctness; no later milestone until P1 passes.

### R01 — Connect and retrieve server info · S after P0

- **Scope/outcome:** `Service/Connection/`, `API/Server/`; connect using verified passive discovery/authentication, expose connection and version/error state. Any startup policy is revisited separately.
- **Contract:** service endpoint → server info; auth/compatibility failures distinguishable. No shared-service ownership implied.
- **Verify/accept:** already-running service reused; no automatic startup or implicit `Service.ensure` under the current decision; revisit startup/lifetime policy explicitly; incompatible/bad auth/timeouts visible; app exit calls no stop. Pinned binary provenance and base `/api/info` are recorded in the Phase 0 sandbox note; remaining compatibility/error/lifecycle checks stay open for R01.
- **Non-goals:** sessions, remote URL interface or service restart workaround. R02 separately owns live SSE lifecycle evidence. Provider approval is required before provider-dependent R06/R10/R11 scenarios.

### R02 — Live event diagnostic checkpoint · S after R01

- **Scope/outcome:** `State/ConnectionEventOwner/`, Diagnostics; one connection-owned live consumption task with subscription/failure indicator.
- **Contract:** F06 envelopes → diagnostic event type/count, no promised historical log.
- **Verify/accept:** observe real stream marker/event from pinned backend; remount/close view does not duplicate subscribers; failure visible, cancellation clean. Record exact evidence before chat work.
- **Non-goals:** business reducers, replay, exposing token/raw private payloads. R01 and R02 are separately assigned bounded tasks.

### R03 — One project/location picker · S after R01

- **Scope/outcome:** `Features/ProjectPicker/`, `State/ActiveLocation/`; native directory picker and verified project/location resolution.
- **Contract:** chosen directory → explicit location plus distinct backend project identity, not global request default.
- **Verify/accept:** cancel, inaccessible/moved directory and same-project worktree path cases; restored invalid selection asks for recovery; approved location used in actual requests.
- **Non-goals:** multiple projects, creating worktrees or adding broad permissions.

### R04 — Root session create/load · S after R03

- **Scope/outcome:** `API/Sessions/`, `State/Sessions/`; create, list/get and load one visible root; retain local last selection only.
- **Contract:** verified list paging/create context/session response → stable summary and history hydration request; uncertain create remains unknown.
- **Verify/accept:** backend can contain multiple roots although UI presents one; load/restart retrieves true title/location; rejected/ambiguous creation does not fabricate success or duplicate.
- **Non-goals:** tabs, deletion, client conversation database.

### R04a — Server-backed session rename · S after R04

- **Scope/outcome:** session update adapter and `Features/SessionManagement/Rename/`; explicit rename action.
- **Contract:** pinned update semantics → server-confirmed title, not local alias.
- **Verify/accept:** rejection and lost reply reconcile; title agrees after refresh/restart and in TUI; navigation label derives from authoritative summary.
- **Non-goals:** backend project rename, deletion or optimism that hides failed updates. Do not overlap edits to R04's shared adapter.

### R05 — Primary agent and model selection · P after R04 interfaces

- **Scope/outcome:** selection adapters and `Features/Selection/`; discovered agents/models with independently maintained selection.
- **Contract:** available primary identifiers/defaults → documented session/prompt selection operations. Build/Plan displayed when available; restrictions enforced by backend.
- **Verify/accept:** agent switch retains valid model; absent/disallowed agents/models yield truthful fallback/error; configured values not hardcoded.
- **Non-goals:** local Plan enforcement, variants/authentication settings.

### R06 — Text draft and prompt submission · S after R04/R05

- **Scope/outcome:** `Features/Composer/`, prompt adapter; multiline text, send/disabled/submitting/error states and draft retention.
- **Contract:** selected session/agent/model + draft → documented prompt mutation. Accepted response/live authoritative message establishes success.
- **Verify/accept:** empty text, repeated click, busy conflict, cancellation and server rejection; live accepted prompt visible in TUI; draft not discarded on failure/ambiguity.
- **Non-goals:** simulated successful user message, automatic timeout retry, advanced input.

### R07 — Structured transcript adapter · P after R04 projection freeze

- **Scope/outcome:** `Domain/Transcript/`, `Features/Transcript/`; ordered stable message/content projections from actual current wire schemas, generic expandable tools/reasoning/errors.
- **Contract:** history/current message variants → structured renderable records with unknown-safe fallback. Do not force legacy parts into current wire model.
- **Verify/accept:** mixed output, identity/order, repeated full updates, tool transitions, unknown variants and malformed entries do not duplicate content/crash; semantic agreement with TUI.
- **Non-goals:** all assistant output as appended string, specialized cards or full Markdown.

### R08 — Live projection and hydration races · S after R02/R07

- **Scope/outcome:** `State/SessionProjection/`; session-keyed stores, buffering and scoped refresh epochs.
- **Contract:** snapshots/pages + live envelopes → conservative reconciled projection. Establish stream before/alongside snapshot using verified readiness semantics; preserve changes/tombstones across overlapping fetches; use IDs/revisions only if supplied.
- **Verify/accept:** event during slow fetch, late stale response, duplicate/removal, cursor overlap and parentless unknown event; stale data cannot silently overwrite newer facts. Unknown routing triggers refresh, not guess.
- **Non-goals:** fabricated total order/exactly-once guarantee, view-owned state or subscriptions.

### R09 — Execution status and interrupt · S after R08

- **Scope/outcome:** interrupt adapter, `State/ExecutionStatus/`; idle/working/blocked/interrupted/failed/completed presentation with documented provenance.
- **Contract:** server facts and confirmed interrupt → status; silence is not completion. Store UI attention separately from execution facts.
- **Verify/accept:** interrupt a real run, handle busy/unknown reply and reconcile; disconnected screen never claims execution stopped.
- **Non-goals:** backend scheduler, local inference from token timing.

### R10 — Pending permissions · P after R08 pending-input contract

- **Scope/outcome:** permissions adapter/store/view and focused tests; resource/session identity, supported approval/rejection choices and response progress.
- **Contract:** authoritative pending list/request → exact response mutation; double settlement handled.
- **Verify/accept:** real blocked tool becomes actionable, once/reject as supported resumes/halts correctly; reconnect and TUI settlement clear or update request; duplicate clicks cannot send anonymous approval.
- **Non-goals:** autoapprove workaround, inventing response choices or saved policy editor.

### R11 — Blocking forms/questions · P after R08 pending-input contract

- **Scope/outcome:** forms adapter/store/view; verified fields, required/optional validation and supported submit/cancel.
- **Contract:** session/location pending forms → validated typed answer; unsupported field preserved safely with explanation instead of fake submission.
- **Verify/accept:** blocking form presents inputs, invalid answer disabled, success resumes; canceled/expired/already-settled and reconnect cases handled. Require live demonstration using suitable approved configuration; fixture alone doesn't close live gate.
- **Non-goals:** text-only permission masquerading as form, arbitrary invented question schemas.

### R12 — Unknown mutation outcome policy · S after R06/R09/R10/R11

- **Scope/outcome:** `State/MutationReconciliation/`, focused action integration; pending/confirmed/rejected/unknown outcomes for prompt/create/interrupt/replies.
- **Contract:** lost response → authoritative read/inbox/history checks, verified correlation where possible; otherwise visible unresolved ambiguity and explicit manual recovery.
- **Verify/accept:** simulate acceptance followed by response loss; no automatic duplicate prompt/reply/create. Preserve original draft/context and explain when outcome cannot be proven. Do not assume unsupported idempotency key.
- **Non-goals:** global exactly-once guarantee or treating all errors as rejection.

### R13 — Reconnect and authoritative resync · S after R08/R12

- **Scope/outcome:** `State/ConnectionRecovery/`; bounded backoff/cancellation, subscribe-again, scoped session/history/execution/permission/form refresh and reconciling state.
- **Contract:** live-only failed subscription → new generation + snapshots; state stale until recovery evidence.
- **Verify/accept:** disconnect during output/form/permission/hydration; late old fetch cannot regress state; TUI-created/settled changes recovered; one subscription remains.
- **Non-goals:** replaying missed events or forced service restart.

### R14 — Paging, bursts and P1 integration · S after R13

- **Scope/outcome:** `State/HistoryLoading/`, buffer policy/tests; integrator wires plain single-thread layout and P1 record.
- **Contract:** verified page/cursor semantics and bounded event queues → preserved identities/tombstones, batching and overflow-resync. Keep transport/reduction distinct from UI rendering.
- **Verify/accept:** large paged history, active updates, slow consumer/overflow and interrupted page; no unbounded main-thread work or lost blockers. Complete P1 live demo and all established checks.
- **Non-goals:** final styling, eager preload every historical session or claiming transient missed updates can always be reconstructed.
