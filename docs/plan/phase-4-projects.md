# Phase 4 — Threads grouped by project, skeleton UI

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** P3. **Exit P4:** two repositories/locations with grouped root tabs, compact/detailed plain layouts sharing one projection, accurate inactive-project attention, truthful project overview and restart isolation.

**Non-goals:** final floating chrome, worktree creation, inferred project identity, drag reorder moving sessions between projects or local hide deleting backend work.

**Waves:** J01 → J02 → J03 settles context across existing features. J04/J05/J09 can overlap only after shared action/projection shapes are fixed; J04 owns projection, UI workers wait for freeze. J04b grouped UI, J06/J07 shared integration sequential, J08 gate last (including J09).

### J01 — Project/location/worktree audit · S after P3

- **Scope/outcome:** `Domain/ProjectContext/`, operation scoping ledger; distinguish backend project/location/directory/workspace/worktree and pinned session context.
- **Contract:** official scope for every already-used operation/event → immutable request context and composite store keys where required.
- **Verify/accept:** same project/two locations and two projects/same display name cannot collide; uncertainty triggers explicit refresh/error, not ambient directory fallback.
- **Non-goals:** assuming session operations require directory if server resolves it, or assuming they don't without verification.

### J02 — Opened/hidden project registry · S after J01

- **Scope/outcome:** `State/Projects/`; backend discovery plus local opened/hidden/alias presentation entries.
- **Contract:** project list/location resolver + local preferences → navigation membership, not new backend persistence.
- **Verify/accept:** missing/offline/reopened project, local alias distinct from server rename, hide sends no deletion/update; recent path privacy considered.
- **Non-goals:** arbitrary backend project rename or independent repository database.

### J03 — Explicit scoped calls across existing features · S after J01/J02

- **Scope/outcome:** scheduled API/state caller integration audit, feature-owned test updates; no concurrent adapter modifications.
- **Contract:** scope ledger → every request targets appropriate project/location or documented server-pinned session.
- **Verify/accept:** interleaved A/B requests preserve contexts, stale A response cannot replace B view, permissions/forms remain session-attributed; no global mutable working directory.
- **Non-goals:** unrelated API refactor or duplicating connection per project.

### J04 — Grouped navigation projection · S after J03

- **Scope/outcome:** `State/NavigationProjection/`; `ProjectNavigationItem`, root-tab grouping, active project/session, expansion/local order.
- **Contract:** registry/tabs/tree → shared compact/detailed view input and commands. Children remain root-associated, not automatically outer tabs.
- **Verify/accept:** collapse/local close preserve backend work; hidden project active work stays in attention; project-selected/no-session state explicit.
- **Non-goals:** layout-specific duplicate state or final bubble appearance.

### J05 — Add/switch/hide project UI · P after J04 action freeze

- **Scope/outcome:** `Features/Projects/Picker/`; plain native directory add/open/switch/hide workflow.
- **Contract:** selection → explicit context/navigation action; failure/cancel doesn't alter another session's draft.
- **Verify/accept:** two real repositories switch correctly, inaccessible path recovery, project vs current session choice predictable.
- **Non-goals:** folder drop styling, worktree mutations or backend project edits.

### J04b — Grouped compact/detailed skeleton · P after J04 freeze

- **Scope/outcome:** `Features/Projects/NavigationSkeleton/`; replaceable horizontal contexts and vertical project groups/subordinate root rows from one projection.
- **Contract:** J04 → layout-only presentation; active item/overflow/local close action preserved.
- **Verify/accept:** P4 actually displays two projects/several tabs in both arrangements; session attribution clear, no overlap, inactive blockers reachable, layout switch retains view context.
- **Non-goals:** polished floating surfaces/animation, grouping as backend session move. Never edit J04 concurrently.

### J09 — Truthful project overview · P after J04 read contract

- **Scope/outcome:** `Features/Projects/Overview/`, scoped projection; project selection with no active session shows verified identity and recent sessions.
- **Contract:** available backend data → overview sections or honest loading/unavailable/error state. Later C03/C01/C02/E07 supply branch/files/activity if exposed.
- **Verify/accept:** two locations of one project, two separate projects, missing data and no current tab; no generated summary or fabricated recents/tasks.
- **Non-goals:** client todo database, pretending all mockup fields have endpoints, styling the final overview.

### J06 — Per-context draft/navigation restore · S after J04/J05/J04b

- **Scope/outcome:** `State/LocalPreferences/` migration and restoration; selected tab, drafts, expansion/order/scroll scoped by verified identities.
- **Contract:** local schema → safe restoration even if directory/session moved or missing.
- **Verify/accept:** A/B draft isolation after restart, same-project separate worktrees do not merge context, corrupt/migrated prefs safe; no transcript persistence.
- **Non-goals:** server sync of local order or automatic prompt resubmission.

### J07 — Cross-project event and attention integration · S after J03/J04/J06

- **Scope/outcome:** central dispatcher/attention owner updates; context-aware routes and recovery for offscreen projects.
- **Contract:** verified event scope → correct session store, or scoped conservative refetch.
- **Verify/accept:** concurrent same-name A/B sessions/child blockers, hidden projects, reconnect; no context leak into active composer/transcript.
- **Non-goals:** multi-server support or guessed routing by current UI selection.

### J08 — P4 integration gate · S after J07/J09

- **Scope/outcome:** integrator's P4 evidence and source-of-truth audit.
- **Verify/accept:** two repos, several roots, child execution and inactive blocker; grouped compact/detailed skeleton and overview, restart; TUI agrees and client quit leaves all execution/service intact. Recheck P1–P3.
- **Non-goals:** final styling or silently redefining local project close as destructive.
