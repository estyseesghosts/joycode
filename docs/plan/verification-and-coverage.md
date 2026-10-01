# Verification, gates and source coverage

[Roadmap index](README.md)

This is the verification **plan**. F02 established the app harness and Debug commands. The prior
Debug baseline was 84 unit test cases (83 passed and one skipped opt-in live test), one UI
smoke test passed, and the Debug app build passed. Current focused offline verification is 85
passed, 1 skipped, 0 failures; the opt-in live test passed 1/1 and fixture-focused tests passed
15. A default full build/test attempt hung/faulted in the Xcode test runner and UI-test
initialization; it was not an assertion failure and is not a new successful full-suite result. F10 also has a passed unsigned
Release app compile; its Release test attempt failed at test-module compilation before any
tests ran because the scheme/testability configuration is incompatible. No Release test,
broad session/workflow, provider, or distribution result is established; the narrow pinned
info/event/coexistence result is recorded in the sandbox note. See the [deferred-work
ledger](deferred-work.md) and [Release validation plan](release-binary-validation.md); workers
must record exact commands and never invent unestablished invocations.

## Test layers

| Layer | Evidence and responsibilities |
|---|---|
| Contract | Release/schema/generated-client provenance; sanitized real examples plus separately labeled synthetic edge cases; requests/context/auth/error/stream/frame parsing |
| Unit/state | Deterministic clock/transport; reducers/identity/ordering/unknown variants; refresh generations/pagination/tombstones; persistence migrations, retry policy |
| UI/native | Semantics/keyboard/VoiceOver, screenshots/geometry, text editing/IME, window/fullscreen/multidisplay, contrast/transparency/motion; isolated fixture cards are not live evidence |
| Live | Opt-in pinned V2 and approved disposable projects; actual session/blocker/auth/PTY behavior, official TUI coexistence and authoritative recovery |
| Release | Real security/performance/version/install/signing/update results; Release app compilation is distinct from optimized Release tests and artifact proof; explicitly blocked if environment/credentials unavailable |

Tests must not mutate real user projects, credentials, backend config, DB or shared-service registration without explicit test authorization. For lifecycle/destructive tests use an approved isolated environment; don't stop a shared service to prove stop behavior. Provider-dependent live tests need consent/cost bounds and clearly named configuration. Current F09 API diagnostics will not start or ensure the service implicitly; R01 must receive explicit approval before any future startup path. Record side effects for any approved startup diagnostic.

## Repeated invariants

1. One connection-owned live subscription, no view/tab/window duplicate.
2. Unmounted/background session state and blockers remain accessible.
3. Session/project/location/worktree/tab identity distinct; no cross-context fetch/event/draft leak.
4. No implicit interrupt/delete on local close/hide/collapse/reorder or window quit.
5. Service reused and never stopped merely by client exit.
6. Unknown message/event/tool/schema safe fallback or explicit incompatibility, not crash/silent disappearance.
7. Live-only gaps recover by authoritative hydration, not replay assumption.
8. Snapshot during events, stale fetch after context change, duplicate updates, deletion tombstones across overlapping pages and buffer overflow handled explicitly.
9. Unknown mutation not silently rejected or automatically resubmitted; use verified correlation/reads or visible ambiguity.
10. Pending permissions/forms recover and externally settled requests disappear/reconcile.
11. Local-only versioned data is drafts/navigation/settings/review notes, not backend transcript/credentials.
12. Production controls perform implemented actions; preview fixtures never masquerade as live functionality.
13. Native text editing/IME/focus/selection survives navigation/layout changes, with sufficient accessibility and hit targets.
14. Logs/fixtures/banners/crash reports don't leak credentials/private content; untrusted URLs/output never become commands.

## Milestone gate matrix

| Gate | Required demo/check | Blocker if absent |
|---|---|---|
| P0 | F01–F09 harness/contract/mock-fixture gates; exhaustive source-derived workflow inventory mapped to owner/status/next gate with uncertainties flagged; narrow pinned service-info/event/TUI-Joycode coexistence evidence; two reviewed sanitized captures; exact test results; recorded user N14 exclusion and Phase 0 result | No dependent feature work on guessed wire contract |
| R02 checkpoint | Real server info/authenticated live subscription, visible failure, safe lifetime | No chat implementation integration on fake connection |
| P1 | Real Build/Plan if discovered, session create/load/rename, structured tools/output, permission and form, interrupt/restart/reconnect, ambiguous send, TUI agreement | Single useful client not accepted without blockers/recovery |
| P2 | Concurrent children, independent histories, correct child request, parent return/restart | No tab phase built on view-dependent child stores |
| P3 | Concurrent roots/children, tabs close/reopen/order/restore, inactive/closed-tab attention, explicit deletion | No project expansion until concurrency safe |
| P4 | Two projects/locations, compact/detailed grouped skeleton, truthful overview, draft isolation/inactive blocker/restart | No final design on ambiguous context model |
| P5 | All visual chapters, card previews, native transparent canvas, both layouts/overflow, accessibility and unchanged live features | Design not complete if rich card families never designed |
| 6A | Supported attachments/references/completion/commands/skills and busy delivery with unknown-outcome recovery | No frontend queue masquerading as backend inbox |
| 6B | Rich long transcript/metadata/context and supported compaction/fork/revert/transfer | No local undo/summarizer as backend parity |
| 6C | Files/search/VCS/diff/notes/worktree and source-aware overview | No wrong-context repository action or fictional search/comments |
| 6D | Supported variants/key/OAuth/command/credentials/MCP/config workflows and secrecy | Unsupported methods/scopes explicitly dispositioned |
| 6E | Shell jobs and actual interactive server PTY input/output/resize/lifecycle; runtime-source matrix | Static terminal-output card insufficient |
| 6F | Declared RPC + unchanged representative plugin trials, chosen support scope/exclusions | No arbitrary JSX compatibility promise |
| 6G/N14 | All earlier regressions, approved optional windows, security/performance/compatibility, real release checks, closed parity inventory; N14 must resolve D08 by optimized ReleaseTest evidence or explicit approved disposition | “Complete” cannot conceal unapproved gaps or missing release/artifact proof |

### Gate evidence record template

For each milestone record:

- Date, owned slice IDs, files/diff inspected, reviewer findings and owner fixes.
- Toolchain/macOS target, OpenCode release, schema/client revision and test-project scope.
- Exact commands actually run, exit/result, skipped checks and reasons. No summary-only “all tests pass.”
- Live scenario, authoritative/TUI comparison, approved destructive side effects and cleanup.
- Visual/native matrix where relevant; explicit distinction between preview, mock and live proof.
- Known limitations/unknown contracts, user decisions/exclusions, compatibility changes and next entry conditions.

Gate failure returns to owning slice or a newly bounded follow-up, not to a revised claim that the missing behavior is complete. Release prerequisites begin early: secret handling F04/F07, lifecycle R01/R02, race testing R08, accessibility in each interactive feature and bounded state R14/T05; N08/N09 consolidate, not introduce these concerns for the first time.

## Official TUI workflow inventory

F10 creates an evidence-backed living inventory; each phase updates it, and N14 closes approved whole-product scope. Phase 0 requires every identified workflow to be inventoried, mapped to an owner and next gate, conservatively classified, and marked with uncertainties; it does not require N14 approval to begin Phase 1. Suggested columns:

`user workflow | pinned TUI evidence | API/event contract | context/safety | native slice | supported/blocked/deferred/alternative | mock/UI/live test | decision approval | supported versions`.

Include ordinary prompting/agents/models, root/child navigation, commands/skills/references/attachments, busy inputs, permission/forms, history/context/compaction/fork/revert/transfer, session lifecycle/project/worktree, files/search/review/VCS, shell/PTY, provider authentication/credentials/MCP/config, plugins/runtime indicators, native preferences/attention/restoration. Inventory can identify additional workflows not explicitly named here; add bounded slices before claiming completion. Endpoint count is not the target. Experimental functions/terminal-only features need explicit decisions, not silent omissions or impossible blanket commitments.

## Detailed design chapter coverage

Each row refers to [the original design specification](../opencode_client_design.md). Phase 5 covers appearance and existing interactions; Phase 6 supplies advanced live behavior. Chapter 19 has separate content-family evidence, not merely a generic card screenshot.

| Chapter | Intent | Specific plan ownership/evidence |
|---|---|---|
| 1 | Workframe/floating order/one action/hierarchy | [V01/V03/V16](phase-5-design.md), P5 geometry and action audit |
| 2 | SwiftUI-first, one transparent window, custom components | [V02/V04](phase-5-design.md), native checks; F03 boundaries |
| 3 | Shapes/radii/padding/shadow/border/color/typography | [V01/V04](phase-5-design.md), shared token/theme matrix |
| 4 | Native traffic lights and separate sidebar toggle | [V02/V09](phase-5-design.md), hit-testing/window behavior |
| 5 | Stable workframe/header/scroll/content types | [V03/V12/V13](phase-5-design.md), long mixed content |
| 6 | One attach–field–send row, growth/stop | [V08](phase-5-design.md), [A01/A02/A07/A08](phase-6a-input.md) live input |
| 7 | Common project/session hierarchy and left close | [J04/J04b](phase-4-projects.md), [V05/V06](phase-5-design.md) |
| 8 | Compact row/overflow/internal planning-review-search | [V07/V13](phase-5-design.md), [C02/C05](phase-6c-project-review.md) live panels |
| 9 | Detailed layout and stable dominant frame | [V06/V10](phase-5-design.md), narrow/wide checks |
| 10 | Transparent project stack, expansion/indent/order | [V05/V06/V11](phase-5-design.md), many groups/scroll/local close |
| 11 | Detailed workframe width/content | [V03/V10/V18](phase-5-design.md), large diff/card geometry |
| 12 | Project browsing/overview | [J09](phase-4-projects.md), [V03](phase-5-design.md), [C10](phase-6c-project-review.md) source-backed sections |
| 13 | Active coding/tests/tool activity | [R07/R09](phase-1-single-session.md), [V12/V13/V17](phase-5-design.md), [E07](phase-6e-runtime.md) evidence |
| 14 | Child activity inside workframe, no automatic outer tabs | [H04–H06](phase-2-children.md), [V13](phase-5-design.md) |
| 15 | Responsive/manual mode/continuity | [V10/V15](phase-5-design.md), retained draft/focus/scroll |
| 16 | Hover/select/reorder/context menus | [V04/V11](phase-5-design.md), local vs server action tests |
| 17 | Keyboard and visible focus | [V14](phase-5-design.md), [N01](phase-6g-native-release.md), pointer-free gates |
| 18 | Attachments/folder drop | [V15](phase-5-design.md), [A02](phase-6a-input.md), [N06](phase-6g-native-release.md) |
| 19.1 | Restrained user/assistant messages | [V12](phase-5-design.md), [B01](phase-6b-conversation.md) |
| 19.2 | Code label/copy/file/line/highlight/scroll | [V17](phase-5-design.md) previews, [B01](phase-6b-conversation.md) live |
| 19.3 | Unified/split diff/counts/notes/open/copy | [V18](phase-5-design.md) previews, [C04–C06](phase-6c-project-review.md) live/local note distinction |
| 19.4 | Task status/steps/collapse | [V17](phase-5-design.md) previews, [B02](phase-6b-conversation.md)/[E07](phase-6e-runtime.md) actual source |
| 19.5 | Command/live output/result/expand/copy | [V17](phase-5-design.md) previews, [B02](phase-6b-conversation.md)/[E01](phase-6e-runtime.md) output; E04 separate interactive terminal |
| 20 | Minimal status/attention | [R09](phase-1-single-session.md), [T06](phase-3-tabs.md), [V05](phase-5-design.md) |
| 21 | Semantics/hit targets/contrast/keyboard | [V04/V14/V16](phase-5-design.md), each feature UI checks |
| 22 | Controlled motion/continuity | [V15](phase-5-design.md), Reduce Motion and streaming stability |
| 23 | SwiftUI layout, AppKit window/native editor boundary | [F03](phase-0-foundation.md), [V02/V08](phase-5-design.md), [E04](phase-6e-runtime.md) |
| 24 | Complete compact/detailed layout summary | [J04b](phase-4-projects.md), [V06–V10/V16](phase-5-design.md) |
| 25 | No opaque shell/duplicate/overlap/random floating controls | [V16](phase-5-design.md), full-window negative acceptance audit |
| 26 | Whole design acceptance with many projects/sessions | [V16](phase-5-design.md), P5 matrix plus earlier live regression |

## Client architecture coverage

| Original architectural intent | Plan |
|---|---|
| Objective/native frontend, backend remains authoritative | [README architecture/invariants](README.md), F03, gate audits |
| Native transport/service management and foundation | [F01–F10](phase-0-foundation.md), [R01/R02](phase-1-single-session.md) |
| Session lifecycle/Build–Plan/model/composer | [R03–R06/R04a](phase-1-single-session.md), [B09](phase-6b-conversation.md) inventory |
| Rich transcript and execution/permission handling | [R07–R14](phase-1-single-session.md); forms explicitly added R11 |
| Children/concurrent stores/delegation/permission routing | [H01–H08](phase-2-children.md) |
| Independent sessions/tabs/background attention | [T01–T08](phase-3-tabs.md) |
| Projects/location/worktree separation | [J01–J09](phase-4-projects.md), [C07–C09](phase-6c-project-review.md) |
| Advanced composer and TUI commands | [A01–A08](phase-6a-input.md) |
| Conversation/history/usage/fork/revert/transfer | [B01–B09](phase-6b-conversation.md) |
| Development tools/file/diff/search/review/worktrees | [C01–C10](phase-6c-project-review.md) |
| Providers/models/variants/config/integrations | [D01–D11](phase-6d-connections.md) |
| Shell/terminal/runtime status | [E01–E07](phase-6e-runtime.md), no legacy LSP endpoint assumption |
| Server RPC and TUI-plugin investigation/decision | [X01–X03](phase-6f-plugins.md) |
| Native menus/keyboard/windows/notifications/prefs | [N01–N07](phase-6g-native-release.md) |
| Stability/service-version/security/performance/distribution | Early F04/F07/R08/R13/R14 plus [N08–N14](phase-6g-native-release.md) |
| Incremental slices/mock + live tests/worklog | All phase gates and evidence template above |

## Main risks and stop/decision conditions

- **V2 contract drift:** pin provenance and verify operation families just in time; unknown payload fallback cannot magically make changed mutation semantics compatible.
- **Service management feasibility:** F07-R provides passive discovery now. Any future startup/ensure behavior is a separate, explicitly approved R01 policy/lifecycle slice; choose an isolated helper only with evidence, never stack unsupported registration workarounds.
- **Snapshot/event reconciliation:** prioritize deterministic race tests; when no ordering/correlation exists, honest refresh/unknown-state UI is safer than fictitious exactly-once promises.
- **Project/worktree scope:** explicit keys/immutable request contexts from Phase 0; audit before adding multi-project UI rather than retrofit after data leakage.
- **Custom native chrome:** prototype real focus/hit-testing/accessibility/fullscreen early in Phase 5; native fallback must preserve usability and design separation.
- **UI versus functional completeness:** visual card previews complete P5 design, not P6 workflows. Inventory is the product completion contract.
- **Backend gaps:** LSP/formatter/content search/project config/comments/plugins may lack required current operations. Verify, document, decide; do not substitute old report APIs or quietly omit.
- **Authentication/terminal/plugins:** dedicated threat-model and lifecycle tests; optional bridge/persistent PTY isolated from normal app.
- **Scope expansion:** if a bounded slice exposes a new subsystem, stop and create explicit contracts/slices. Gate cannot absorb an entire hidden feature family.
- **Distribution constraints:** sandbox/helper/service/file access must be demonstrated for chosen channel; signing/notarization unavailable means blocked, not passed.
