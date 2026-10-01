# Phase 3 — Multiple root threads and local tabs

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** P2. **Exit P3:** simultaneous roots, children, local open/close/focus/reorder/restore tabs, background attention and deliberate backend deletion all behave independently.

**Non-goals:** multiple projects, final bubbles, per-tab subscriptions, tab closure deleting or interrupting a session.

**Waves:** T01 → T02 freezes registry/tab contracts. T03/T04 can overlap separate chooser/tab UI files. T05/T06 sequential shared-state work; T07 deletion then T08 integration. Local reorder is implemented in state now, polished drag behavior in V11.

### T01 — Multi-root registry · S after P2

- **Scope/outcome:** `State/SessionRegistry/`; server-backed root listing/hydration/summaries and preserved child trees independent of displayed thread.
- **Contract:** paged list + parent identity → root registry, current/removed/error states.
- **Verify/accept:** unmounted running roots remain addressable; paging/removals do not duplicate or misclassify children.
- **Non-goals:** UI tabs or separate network client per root.

### T02 — Tab identity, draft/focus/scroll and restore · S after T01

- **Scope/outcome:** `State/Tabs/`, sequential local storage extension; tab ID maps session ID, selected/order/open state and per-session view context.
- **Contract:** local commands → local mutation only; default one tab per session.
- **Verify/accept:** open/focus/close/reorder/reopen/restart, retained unsent drafts/scroll, missing session recovery; close calls no backend interrupt/delete.
- **Non-goals:** backend tab persistence or transcript copied into tab model.

### T03 — Create/list/open root UI · P after T01/T02 freeze

- **Scope/outcome:** `Features/SessionChooser/`; chooser, create/open, empty/loading/error states for one project's backend roots.
- **Contract:** registry + session actions → open tab of current server session.
- **Verify/accept:** create second root, reopen closed running root, list paging, uncertain create reconciles rather than duplicate.
- **Non-goals:** auto-child tabs or final navigation strip.

### T04 — Temporary horizontal tab skeleton · P after T02 freeze

- **Scope/outcome:** `Features/Tabs/`; plain replaceable single-row tab navigation, status, close and accessible overflow/next/previous.
- **Contract:** tab projection/actions → selection, no new session authority.
- **Verify/accept:** many tabs keyboard-addressable, active tab visible, unambiguous close action and selected accessibility state.
- **Non-goals:** final styling, wrapped navigation that shifts workframe or backend operations from view.

### T05 — Background event fan-out · S after T01/T02

- **Scope/outcome:** `State/SessionEventDispatcher/`; one stream routes active/offscreen roots and children with bounded store retention.
- **Contract:** verified event scope → session projection or scoped refresh. Unloaded historical sessions need not be eagerly hydrated.
- **Verify/accept:** A/B simultaneous streams with unmounted A, re-open current state, no cross-session content or stale overwrite; eviction triggers honest refresh.
- **Non-goals:** subscriptions per tab or unbounded memory.

### T06 — Global attention · S after T05

- **Scope/outcome:** `State/AttentionCoordinator/`, accessible temporary attention list; pending permissions/forms and completion/failure across closed/background tabs.
- **Contract:** authoritative pending inputs + local read/attention markers → attributed jump/reply paths.
- **Verify/accept:** closed-tab blocker accessible; dismissing badge does not settle server request; foreground focus doesn't hide another request.
- **Non-goals:** OS notifications or server unread state invented from local markers.

### T07 — Explicit backend session deletion · S after T03/T06

- **Scope/outcome:** deletion adapter and `Features/SessionManagement/Delete/`; separately labeled destructive action with confirmation and affected-child semantics verified.
- **Contract:** pinned delete behavior/user policy → confirmed removal or unknown/rejected outcome followed by reconciliation.
- **Verify/accept:** cancel has no server effect, failures leave valid state, confirmed removal updates tabs/tree/registry; deletion consequence for children documented rather than guessed.
- **Non-goals:** delete on tab close or substitute for interrupt.

### T08 — P3 integration · S after T03–T07

- **Scope/outcome:** integrator composition and P3 worklog.
- **Verify/accept:** run two roots, child work on A, switch/close/reopen/reorder/restore tabs and answer offscreen blockers; official TUI agrees; P1/P2 regressions pass with one stream owner.
- **Non-goals:** multi-project or multiwindow feature additions during gate.
