# Phase 5 — Complete floating visual and interaction design

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** P4 functional app and stable navigation/transcript/action seams. **Exit P5:** complete design system, real compact/detailed native floating UI, all specified content families designed in isolated previews, accessible native interactions and unchanged Phase 1–4 functionality.

Design-complete is not falsely feature-complete: future card families are exercised in previews using explicitly labeled fixtures; production surfaces use only verified live data and available actions. Advanced feature wiring follows in Phase 6. An unimplemented button is absent or honestly disabled with explanation, never enabled to simulate success.

**Non-goals:** new execution engine, per-control NSWindows, opaque surrounding panel, permanent rectangular sidebar/full-width toolbar, premature interactive PTY claims, full backend parity.

## Waves and seams

1. V01 freezes tokens, accessible semantics and card/action contracts. V02 window owner and V04 primitives may overlap without shared edits.
2. V03 workframe and V05 navigation component integration. V06/V07 independent detailed/compact files consume frozen bubbles. V08 composer consumes frozen primitives.
3. V12/V13 and V17/V18 can develop disjoint presentation areas from frozen workframe/card contracts, in small waves. Shared tokens stay single-owned. V09/V10 integrate layouts; V11 follows shared selection/order decisions.
4. V14/V15/V16 sequential accessibility/motion/design gate. Production card wiring is not a prerequisite for isolated fixture visual acceptance but every Phase 1–4 live surface must already function.

### V01 — Visual tokens and component contracts · S after P4

- **Scope/outcome:** `Features/DesignSystem/`; common spacing/radius/elevation/color/typography/density/focus/hit-area families and small component inputs/actions.
- **Contract:** prose specification → one visual language shared across both layouts. Freeze workframe slots, card variants and project/session controls before parallel writers.
- **Verify/accept:** light/dark/accent/increased-contrast and readable text fixtures; one token change updates both modes; distinguish selection without color alone.
- **Non-goals:** giant theme framework, hardcoded bright-blue mockup palette or all components in one file.

### V02 — Single transparent native window · P after V01

- **Scope/outcome:** `App/Window/`; transparent NSWindow, hidden conventional chrome, native resize/minimize/zoom/fullscreen, traffic-light feasibility, custom safe dragging regions.
- **Contract:** one window hosts SwiftUI root canvas; no opaque background joins independent surfaces. Retain ordinary macOS focus/window behavior.
- **Verify/accept:** real native checks for multiple displays, fullscreen, resize limits, drag vs control hit testing, focus, reduce transparency/increased contrast and screen capture; safe fallback maintains separation without illegibility.
- **Non-goals:** separate window for each floating bubble, local service tied to window lifetime, sacrificing native controls for screenshot fidelity.

### V03 — Workframe and project overview presentation · S after V02

- **Scope/outcome:** `Features/Workframe/`; stable dominant rounded surface, session-only header, scrolling content, internal panel slots and J09 overview restyle.
- **Contract:** selected session/project projection → same workframe silhouette for conversation/overview/loading/errors. Global project navigation remains outside.
- **Verify/accept:** long transcript scroll leaves frame/composer stationary; no active session yields truthful overview; content mode doesn't relocate exterior controls.
- **Non-goals:** opaque outer shell, project navigation duplicated in header, fabricated overview fields.

### V04 — Floating primitives · P after V01

- **Scope/outcome:** `Features/DesignSystem/Bubbles/`; capsule, circle, separate close bubble, hover/focus/selected/disabled states.
- **Contract:** tokenized appearance + labeled action → reusable accessible controls. Larger hit region than small visual circle where needed.
- **Verify/accept:** keyboard/VoiceOver labels and roles, hit targets, contrast, pointer states; no aggressive hover scaling or duplicated action semantics.
- **Non-goals:** networking or project-specific state in primitives.

### V05 — Project/session bubble components · S after V04

- **Scope/outcome:** `Features/Navigation/Bubbles/`; project parent, session child, new actions, subtle attention/selection, collapse and local tab close.
- **Contract:** J04 navigation projection → consistent presentational components. Project and session selected independently.
- **Verify/accept:** long titles/loading/attention/collapsed states; clear parent-child relation without color; close never backend delete/interrupt.
- **Non-goals:** local alias passed off as backend rename or overloading pills with status text.

### V06 — Detailed floating project stack · P after V05

- **Scope/outcome:** `Features/Navigation/Detailed/`; left transparent scroll stack of project groups and subordinate session rows, larger group gaps, new-project pill.
- **Contract:** J04 → vertical presentation; every row `(x) [session]` with independent fixed-diameter circular x on the left.
- **Verify/accept:** fixed spacing unaffected by title length; no overlap/embedding of sessions in project pill; collapse hides views only; stack scroll doesn't move workframe; no full-height sidebar surface.
- **Non-goals:** automatically promoting every child/tool invocation into navigation.

### V07 — Compact single-row navigation · P after V05

- **Scope/outcome:** `Features/Navigation/Compact/`; shared pills, one baseline, leading native/control area, contexts, overflow and new-session action.
- **Contract:** same state as detailed layout → compact labels carrying project/session attribution.
- **Verify/accept:** preserve leading controls and active context at narrow widths, scroll/collapse overflow rather than wrapping or shrinking unreadably; active item stays reachable/visible.
- **Non-goals:** duplicated navigation store or second toolbar strip. Separate files from V06; primitive changes serialized.

### V08 — Detached composer row · S after V03/V04

- **Scope/outcome:** `Features/Composer/Floating/`; exactly `(attachment) [field] (send/stop)` below frame, multiline growth with internal scroll ceiling.
- **Contract:** existing R06/R09 actions → ready/disabled/submitting/running/interrupting/error states. Attachment initially disabled/explained until A01/A02.
- **Verify/accept:** one attach action only, send transforms into stop where workflow permits, no second duplicate stop; keyboard submit/newline/selection, draft/focus across contexts and layout.
- **Non-goals:** fake attachment success, input inside conversation scroll, rich editor not justified by needs.

### V09 — Window controls and sidebar toggle · S after V02/V06/V07

- **Scope/outcome:** `Features/WindowControls/`; native traffic lights positioned as independent cluster, separate sidebar toggle above stack or at leading compact row.
- **Contract:** native window actions + local visibility state → unobstructed controls with shortcut/accessible labels.
- **Verify/accept:** show/hide/focus and drag do not conflict; native minimize/zoom/close still work; no full-width titlebar/toolbar surface introduced.
- **Non-goals:** window controls in session header or replacing all native behavior with decorative dots.

### V10 — Responsive layout/manual override · S after V06/V07/V08/V09

- **Scope/outcome:** `Features/Layout/`, sequential preference extension; measured breakpoint and optional persistent forced mode.
- **Contract:** one selected context/workframe → layout only. Preserve draft, editor selection, focus, scroll and child navigation.
- **Verify/accept:** resize repeated during streaming; forced detailed narrow mode truncates/reduces stack yet preserves frame minimum and close targets; explicit collapse, no accidental overlap.
- **Non-goals:** app-wide crossfade that recreates state or two execution architectures.

### V11 — Context menus and local reorder · S after V10

- **Scope/outcome:** `Features/Navigation/Interactions/`; standard menus, drag reorder groups/tabs, keyboard equivalent.
- **Contract:** implemented server actions clearly separated from local hide/close/alias/order; only expose available fork/etc once wired later.
- **Verify/accept:** project group moves as unit, session order local within project, click still selects; cross-project dragging cannot silently change backend context.
- **Non-goals:** server session move disguised as reorder or menu dead buttons.

### V12 — Live basic transcript appearance · P after V03/R07 freeze

- **Scope/outcome:** `Features/Transcript/Presentation/`; restrained assistant/user styling and generic reasoning/tool/result/error/status rendering already live in P1–P4.
- **Contract:** structured ordered projection → selection/copy/expand presentation with unknown fallback.
- **Verify/accept:** mixed long content readable, no giant colored assistant bubble, copy preserves content, accessible statuses; no regressed merge behavior.
- **Non-goals:** implementing advanced session actions or dropping unknown records for visual neatness.

### V13 — Internal panels and agent activity · P after V03 slots freeze

- **Scope/outcome:** `Features/Workframe/InternalPanels/`; common file/task/search/review panel geometry and real child activity integration.
- **Contract:** available feature slots → inside-frame panels, not global navigation surfaces. Fixture panels stay in previews until live sources exist.
- **Verify/accept:** tool/content mode changes leave outer geometry stable; child activity and keyboard navigation usable; unavailable production modes hidden/explained.
- **Non-goals:** arbitrary tool producing exterior floating window or fake task database.

### V17 — Code/task/terminal-output visual families · P after V01/V03 freeze

- **Scope/outcome:** `Features/Cards/Code/`, `Task/`, `TerminalOutput/` and isolated visual fixtures. If this becomes more than one bounded assignment, give each family a fresh worker with those disjoint directories.
- **Contract:** small explicit card projections → design-complete code label/copy/line layout; task completed/active/pending/collapse; terminal command/output/result/expand geometry.
- **Verify/accept:** preview matrix narrow/wide, empty/running/error/long content, contrast, selection and accessibility. Verify synthetic actions only in preview harness, never production façade.
- **Non-goals:** syntax engine, invented task-status endpoint or interactive PTY. B01/B02/E01 supply later live wiring.

### V18 — Diff/search visual families · P after V01/V03 freeze

- **Scope/outcome:** `Features/Cards/Diff/`, `SearchResults/` and isolated fixtures; unified/split geometry, file headers/counts, notes and structured result paths.
- **Contract:** frozen visual card data/actions → cohesive preview components; annotation meaning remains local unless verified otherwise.
- **Verify/accept:** long paths/hunks/results, missing metadata, empty/error/loading, keyboard focus and hit regions; share tokens with V17 without concurrent token edits.
- **Non-goals:** backend grep inferred from file-find, shared server comments or enabling unsupported review actions. C02/C05/C06 wire production.

### V14 — Keyboard/focus/VoiceOver integration · S after V08–V13/V17/V18

- **Scope/outcome:** focus graph/command integration and UI tests; next/previous session/project, mode/sidebar, composer, new/close, blockers and implemented search/command entry.
- **Contract:** existing valid actions → pointer-free workflow with visible focus and labeled selected/expanded states.
- **Verify/accept:** complete P1–P4 keyboard path, standard text editing/IME unbroken, VoiceOver attribution for circular close/buttons and structured content; sufficient contrast/hit area.
- **Non-goals:** arbitrary TUI keymap compatibility or shortcuts hijacking native editor commands.

### V15 — Motion and drop surfaces · S after V14

- **Scope/outcome:** common restrained transitions/Reduce Motion path, project folder drop to existing picker action; preview-only attachment drop until A02.
- **Contract:** local layout/selection transitions → spatial continuity, no view-owned execution changes.
- **Verify/accept:** no moving frame during streaming, no focus/scroll loss or overlap; cancelable folder drop; supported targets clear and unsupported file drops rejected truthfully.
- **Non-goals:** constant pulse/bounce, permanent drop zone or silent broad file access.

### V16 — Complete design acceptance · S last

- **Scope/outcome:** integrator screenshot/geometry/accessibility record and owner-assigned fixes.
- **Verify/accept:** all 26 design chapters mapped and checked; compact/detailed many projects/tabs; all card families in labeled previews; all existing live surfaces functional; light/dark/contrast/reduced motion/transparency, small/large/fullscreen/multidisplay checks. Rerun P1–P4.
- **Non-goals:** calling previews live parity or accepting opaque shell because one image depicts one.
