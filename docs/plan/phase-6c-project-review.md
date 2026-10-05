# Phase 6C — Files, search, review and worktrees

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** P5, J01 explicit contexts. **Exit 6C:** truthful filesystem/search/VCS/review surfaces, worktree operations, source-aware project overview, all scoped correctly and restored safely.

**Non-goals:** independent Git authority, client indexer/runtime without separate approval, silent repository writes, collaborative server comments invented from mockup, worktree as tab identity.

**Waves:** C01/C02/C03 independent read feature adapters after scope freeze. C04 diff projection follows C03; C05 consumes it. C06 local annotations, C07 worktree selection may overlap disjoint areas after contracts; C08/C09 destructive worktree stages sequential. Shared overview integration C10 last.

### C01 — Filesystem browse/read/preview · P

- **Scope/outcome:** filesystem adapter and `Features/Files/`; list/read location-scoped paths, supported text/binary metadata and inside-frame preview.
- **Contract:** verified path/security/size semantics → bounded read state and safe open/reveal action.
- **Verify/accept:** symlink/traversal, missing/deleted file, large/binary/encoding, stale location response and backend edits; preview cannot point at another project's path.
- **Non-goals:** writing/editing by default or broad local filesystem permission.

### C02 — Find/search production wiring · P

- **Scope/outcome:** `Features/Search/`, verified adapters; wire V18 results, path/type/count metadata, cancelable filters and file navigation.
- **Contract:** current file-find/content-search capabilities → honest results. If grep/content search lacks API, record gap or approve backend command/RPC/native alternative before implementation.
- **Verify/accept:** zero/large results, rapid query generation, cancellation, project switch, missing file; fs-find is not mislabeled content grep.
- **Non-goals:** unapproved local indexer or pretend web/document/task search tabs without source.

### C03 — VCS branch/status · P

- **Scope/outcome:** VCS status adapter and `Features/VCS/Status/`; branch/changed files/refresh/errors from backend.
- **Contract:** project/location/worktree → status projection; explicit recency/staleness.
- **Verify/accept:** clean/dirty/untracked/deleted, non-Git directory, worktree switch and refresh after agent edits; backend remains authoritative.
- **Non-goals:** Git subprocess alternate state store or auto repository mutation.

### C04 — Repository/session diff fetch and model · S after C03

- **Scope/outcome:** diff adapters and normalized `Features/Review/DiffModel/`; distinguish repository working/base/mode diff from session-turn changes.
- **Contract:** verified diff modes/base/line metadata → immutable file/hunk projection frozen for renderer.
- **Verify/accept:** added/deleted/renamed/binary/huge file, stale base, unknown response and context change; UI source labels correct.
- **Non-goals:** applying patches, split-render implementation or guessed line positions.

### C05 — Live unified/split diff views · P after C04

- **Scope/outcome:** bind V18 diff components to C04 with counts, file list, hunk navigation, copy/open-file and accessible modes.
- **Contract:** normalized diff → consistent cards/inside-frame review panels, width-adaptive unified/split choice.
- **Verify/accept:** long/empty/rename hunks, line alignment, independent horizontal scroll, keyboard/VoiceOver, performance; no giant outer review window.
- **Non-goals:** server comments or edit application absent contract.

### C06 — Reviewed marks and local line notes · S after C05

- **Scope/outcome:** `State/LocalReview/`, annotation UI; explicit local-only reviewed state/notes optionally inserted as user-selected prompt context.
- **Contract:** diff/base identity → versioned local marks with invalidation/reanchor policy. Backend sharing requires separate verified mutation, never implied.
- **Verify/accept:** changed base invalidates/reanchors safely, no note falsely shared, correct line/file/context sent only on explicit user action; privacy retention decision applied.
- **Non-goals:** collaborative server comment invention or silent submission of every annotation.

### C07 — Worktree discovery/selection · P after C03/J01

- **Scope/outcome:** worktree list adapter/selector; choose explicit location for new work while existing sessions retain documented pinned context.
- **Contract:** verified project/worktree/location mapping → selected context, not move of existing tabs.
- **Verify/accept:** two worktrees same project isolate drafts/status/files; absent/stale worktree handled; switching doesn't repin active session silently.
- **Non-goals:** creation/removal or local reorder as server move.

### C08 — Worktree create/refresh · S after C07

- **Scope/outcome:** creation/refresh adapters and progress/error UI; approved backend operations.
- **Contract:** documented inputs → confirmed new available location with unknown-create recovery.
- **Verify/accept:** disposable creation/select/refresh, startup conflicts/failure/reconnect; no duplicate creation blind retry.
- **Non-goals:** direct Git commands or removal in same assignment.

### C09 — Confirmed worktree removal · S after C08

- **Scope/outcome:** removal action, in-use warnings and affected-session recovery.
- **Contract:** pinned destructive semantics + user policy → confirmed removed/unavailable state or authoritative error.
- **Verify/accept:** cancellation no effect, dirty/in-use behavior accurately explained, failed removal leaves valid session context, no unrelated directory deletion.
- **Non-goals:** removing merely because project hidden/tab closed.

### C10 — Source-aware overview and 6C gate · S after C01–C09 accepted scope

- **Scope/outcome:** sequential project overview integration plus gate record; add only available branch/files/activity/tasks with source provenance.
- **Contract:** J09 basic overview + verified feature projections → truthful project browsing state. Recent files/actions/pending tasks absent if not exposed, not generated to match image.
- **Verify/accept:** two projects/two worktrees, live changes/search/diff/review/approved removal; TUI/backend comparison and earlier gates; inventory approved gaps explicitly.
- **Non-goals:** overview coordinator becomes new database or gate conceals unsupported search/write workflow.
