# Phase 2 — One root thread with subagents

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** reliable P1. **Exit P2:** one root delegates concurrent work, real children are independently inspectable, parent/child output cannot cross-contaminate, child blockers accessible from parent, hierarchy restored after restart/reconnect.

**Non-goals:** client orchestration/scheduling, every invocation becoming an outer tab, new top-level root-tab UI or expanding every child transcript inside the parent.

**Waves:** H01 settles relationships; H02 and H03 may use separate agent/store areas. H04 starts after H03 projection freeze. H05/H06 share navigation/attention contracts but must not concurrently edit central state. H07/H08 sequential recovery/integration.

### H01 — Relationship contract · S after P1

- **Scope/outcome:** `Domain/SessionTree/`, relationship fixtures; verified parent/child and delegation linkage, including invocations with no persistent child.
- **Contract:** backend identity/metadata → explicit edges, never title/tool-name inference.
- **Verify/accept:** orphans, late child discovery, multiple children, removed/missing parent; unresolved metadata remains unknown rather than fabricated.
- **Non-goals:** local orchestration or guessed children endpoint.

### H02 — Agent modes and custom agents · P after H01

- **Scope/outcome:** agent discovery adapter and selection extensions; primary/subagent/both/custom where current schema supports.
- **Contract:** backend definitions → mode-appropriate choices. Backend decides delegation capability/permissions.
- **Verify/accept:** unknown/custom/configured modes, actual configured subagent discovery; no duplicate Swift registry.
- **Non-goals:** running children locally or UI inventing definitions.

### H03 — Independent child stores · S after H01

- **Scope/outcome:** `State/ChildSessions/`; lazy child history hydration and summaries separate from parent transcript.
- **Contract:** H01 relationships + R08/R14 rules → session-keyed stores with explicit context and background updates.
- **Verify/accept:** two streaming children while parent visible; remount retains state; late fetch doesn't overwrite newer data or parent output.
- **Non-goals:** duplicated transcript in root store, all child histories eagerly loaded.

### H04 — In-workframe activity · P after H03 interface freeze

- **Scope/outcome:** `Features/ChildActivity/`; target agent/name/status/result/error and open link for genuine child inside workframe.
- **Contract:** stable activity projection → view/actions; unavailable child link is absent/explained.
- **Verify/accept:** concurrent children distinguishable; tool-only delegation displayed truthfully; activity never reorders exterior navigation.
- **Non-goals:** floating child windows or automatic outer tabs.

### H05 — Child/parent navigation · S after H03/H04

- **Scope/outcome:** `State/ChildNavigation/`, child transcript view; open child, return parent, preserve scroll/focus/draft context.
- **Contract:** local selection action → display only; execution ownership unaffected.
- **Verify/accept:** completed child inspectable; keyboard return/focus works; switching issues no interrupt/delete.
- **Non-goals:** multiple root tabs or navigation as cancellation.

### H06 — Child attention and blockers · S after H03/H05 action freeze

- **Scope/outcome:** child routing in attention/blocker presentation; identify exact session/resource and return path.
- **Contract:** R10/R11 pending inputs → parent-associated attention without anonymous global approval.
- **Verify/accept:** child request actionable while parent visible; correct request/session targeted; TUI settlement reconciles; parent remains intact.
- **Non-goals:** notifications or merging all requests without identity.

### H07 — Relationship recovery · S after H05/H06

- **Scope/outcome:** scoped child discovery and refresh in recovery owner; include children created while client closed.
- **Contract:** R13 refresh generations + H01 relation evidence → current hierarchy with unknown/removed cases handled.
- **Verify/accept:** reconnect/restart during concurrent children; no duplicate entries or lost blockers; navigation selection recovers safely if child missing.
- **Non-goals:** replay of intermediate child events.

### H08 — P2 gate and architecture review · S after H07

- **Scope/outcome:** integrator's P2 record and boundary fixes assigned to owning slices.
- **Contract:** accepted H01–H07 behavior → live/TUI evidence; confirm no accidental local agent engine or view-dependent state.
- **Verify/accept:** two children, independent inspection, child blocker, restart; rerun P1. Record unavailable metadata as limitation.
- **Non-goals:** adding future features during stabilization.
