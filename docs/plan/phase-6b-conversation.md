# Phase 6B — Rich conversation and session operations

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** P5 and frozen transcript/card projections. **Exit 6B:** accessible rich rendering, actual metadata/context, compaction/fork/revert and approved transfer/lifecycle actions function against backend with clear destructive boundaries.

**Non-goals:** client summarization/undo engine/conversation DB, stripping unknown records, proprietary transfer format or unsupported archive/clear semantics.

**Waves:** B01/B02/B03 independent rendering/metadata scopes from stable domain model. B04/B05/B06 session operations have separate adapters, but shared action menu/registry integration serialized. B07 destructive commit follows B06 preview. B08 gated experiment. B09 integration and parity audit last.

### B01 — Native Markdown and code wiring · P

- **Scope/outcome:** `Features/Transcript/MarkdownCode/`; wire V17 code components to real text with selectable Markdown/code, copy, language/file labels, bounded highlighting and horizontal scrolling.
- **Contract:** real structured text + safe link policy → native presentation. Choose library only after deployment/performance/security check.
- **Verify/accept:** lists/tables/escaping/code/links, partial streaming Markdown, large content/selection and VoiceOver; hostile URL never executed blindly.
- **Non-goals:** browser editor just to render output or unbounded token-level reparsing.

### B02 — Specialized live tool/task/search/output adapters · P

- **Scope/outcome:** `Features/Transcript/ToolCards/`, tool-specific domain adapter files; bind V17/V18 cards to actual verified structured results, retain generic fallback.
- **Contract:** tool schemas/data → file/search/task/plan/diagnostic/terminal-output card projections; inferred prose is not authoritative task state.
- **Verify/accept:** partial/running/success/error, missing fields/unknown tools, result path scoped correctly; real cards/actions inside frame without exterior changes.
- **Non-goals:** executing tools, inventing todo endpoint or terminal card pretending interactive PTY. Split individual tool families into fresh assignments if adapter complexity grows.

### B03 — Reasoning, usage, timing and context · P

- **Scope/outcome:** `Features/Transcript/Metadata/`, context adapter; reasoning preference, verified token/timing/context metadata and absence/error states.
- **Contract:** pinned fields/endpoints → honest visibility/provenance; model-specific availability respected.
- **Verify/accept:** redacted/absent reasoning, incremental usage, model switch/reconnect, accessible context display; billing/cost shown only with supported source and meaning.
- **Non-goals:** guessed token math or assuming every provider exposes same reasoning.

### B04 — Server compaction · S after B03

- **Scope/outcome:** compact adapter/action; request/progress/result/error and busy-operation policy.
- **Contract:** verified compaction → authoritative history/context refresh with R12 unknown-state handling.
- **Verify/accept:** disposable live compaction/reopen agrees with TUI; no blind retry on lost response or hidden draft discard.
- **Non-goals:** local summarizer replacing backend or compaction success from animation.

### B05 — Fork at documented boundary · P after B03

- **Scope/outcome:** fork adapter/action; choose supported message/turn boundary, create and open resulting session.
- **Contract:** backend fork input → server-owned history/location/parent behavior documented before UI.
- **Verify/accept:** original unchanged, inherited context correct, uncertain create reconciles, TUI sees fork; tab registry updated only after confirmation.
- **Non-goals:** local message copy or implicit cross-project move.

### B06 — Stage/inspect/clear revert · S after B03

- **Scope/outcome:** revert adapter preview and `Features/Review/Revert/`; explicit target/consequences, stage and clear without commit.
- **Contract:** verified staged revert semantics → authoritative preview, active-execution constraints and clear result.
- **Verify/accept:** inspect disposable changes, clear leaves intended state intact, stale target/reconnect/error reconciles; UI explains staged versus committed.
- **Non-goals:** local filesystem rollback or generic undo promise.

### B07 — Confirm/commit revert · S after B06

- **Scope/outcome:** commit action, destructive confirmation and affected-history/files refresh.
- **Contract:** approved policy + verified commit → confirmed authoritative change or visible unknown/error.
- **Verify/accept:** cancel causes no commit, actual commit agrees with TUI/files, lost reply reconciles rather than blindly reruns; destructive scope apparent before action.
- **Non-goals:** claiming redo if server doesn't support it or quietly committing when selecting preview.

### B08 — Approved session import/export · P after B03, decision gated

- **Scope/outcome:** transfer adapter/action, native file pickers, format/version/error checks and security disclosure.
- **Contract:** supported experimental transfer format → server export/import, collision/location behavior verified. Check sensitive export content; do not silently alter backend format claiming transparent round-trip.
- **Verify/accept:** disposable round-trip, wrong version/partial import/collision, user warning about sensitive data, no false success; split import/export into separate assignments if needed.
- **Non-goals:** proprietary DB or unverified migration conversion.

### B09 — Lifecycle/view/agent operation parity audit · S after accepted B04–B08

- **Scope/outcome:** integrated session action menus/inventory; account for actual TUI rename/open/fork/compact/revert/export/archive/clear/share/view/environment/move user workflows, only adding verified approved operations.
- **Contract:** inventory maps each action to local/server effect and additional bounded implementation assignment if missing; do not add everything merely because route exists.
- **Verify/accept:** supported actions error/recover correctly, unsupported gaps approved or remain blockers; repeat P1–P5 and 6B demo. This audit is not permission to implement a whole missing family in one patch.
- **Non-goals:** hiding incomplete parity, conflating close/delete/clear/archive or assuming session-view endpoint purpose.
