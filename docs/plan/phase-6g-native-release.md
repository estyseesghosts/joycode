# Phase 6G — Native completion, reliability and release

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** design-complete app; native slices may start in parallel with independently accepted Phase 6 families. Final release waits for the approved inventory and all relevant feature gates.

**Exit:** native actions/settings/windows/attention are consistent, reliability/security/performance/compatibility verified, chosen distribution/update path proven, and every agreed workflow has evidence or user-approved disposition.

The staged Release-build and distribution evidence plan is [Release binary validation](release-binary-validation.md); known blockers are listed in the [deferred-work ledger](deferred-work.md).

**Non-goals:** untested “fully secure/complete” claims, silently enabling remote service exposure, notarization claims without real result, notifications replacing in-app blockers or app quit stopping shared service.

## Waves

N01 native menus/preferences. N02 decision → N03 state → N04 lifecycle only if multiwindow accepted. N05 notifications/N06 clipboard handlers may overlap after their shared action interfaces, without central App edits. N07 restoration sequential storage/window integration. N08 security begins as an early checklist in F04/F07 and is a release remediation gate, not first security consideration. N09/N10 performance/compatibility are independent test scopes; N11/N12/N13 distribution steps sequential after product/security choices. N14 final integration last.

### N01 — Native menus, shortcuts and client preferences · S after V14

- **Scope/outcome:** `App/Commands/`, `Features/Settings/Client/`; coherent action/menu enablement, layout/appearance/accent/reasoning/privacy and supported shortcut preferences.
- **Contract:** existing actions/preferences → native menu/keyboard paths; backend config remains separate D09/D10 surface.
- **Verify/accept:** both layouts, no text editor/IME shortcut hijack, valid-only menu enablement, persisted/migrated prefs and accessible controls. Remapping only if approved with conflict policy.
- **Non-goals:** global config editing from client-pref UI or TUI keymap compatibility assumed.

### N02 — Optional multiwindow decision/contract · S

- **Scope/outcome:** decision log and `WindowID`/selection/draft ownership contract; choose whether windows can show same session and how draft conflicts work.
- **Contract/dependencies:** one connection/subscription/application session registry; agreed local tab semantics. User accepts feature or approves explicit exclusion.
- **Verify/accept:** contract examples handle two windows/one session, attention targeting, window close vs app exit and missing restored session. No duplicate backend execution or transcript copies.
- **Non-goals:** window implementation before decision or extra service per window.

### N03 — Window-local navigation and shared session state · S after accepted N02

- **Scope/outcome:** window navigation/local storage partition and tests; per-window tabs/selection/view context, shared authoritative session stores, agreed draft conflict policy.
- **Contract:** WindowID → local view projection/actions; backend updates and blockers shared through one owner.
- **Verify/accept:** simultaneous different/same session views, cross-window rename/blocker settlement, close/reopen and draft conflict; no duplicate prompt on synchronized action.
- **Non-goals:** native window construction or duplicate event subscriptions. Skip with recorded disposition if N02 declined.

### N04 — Native multiwindow lifecycle · S after N03

- **Scope/outcome:** `App/Window/` integration; new/close/restore/focus windows, native menus/window list and attention jump behavior.
- **Contract:** N03 view state → one-window-per-workspace-surface using same floating components, not window per bubble.
- **Verify/accept:** two windows, multiple displays/fullscreen, last window closes while work continues, focus/restoration; one backend connection owner.
- **Non-goals:** changing shared-service lifetime or simultaneous project-file writers.

### N05 — Consent-aware native notifications · P after N01/T06

- **Scope/outcome:** `App/Notifications/`; completion/failure/blocker notifications for inactive sessions with user authorization, dedupe and privacy policy.
- **Contract:** attributed attention + current visibility → safe notification and deep action that focuses correct project/root/child/window.
- **Verify/accept:** denied consent, foreground/background, settled-in-TUI blocker before click, renamed/missing session, multiple windows if accepted; no private output/secrets in banner by default.
- **Non-goals:** approving directly from banner absent verified safe interaction or replacing in-app pending list.

### N06 — Clipboard, reveal/open and drop hardening · P after relevant features

- **Scope/outcome:** `App/Interaction/` feature-specific handlers; explicit copy/paste/open/reveal and supported file/folder drops.
- **Contract:** selected scoped content/URL/path + user action → validated macOS handoff; untrusted terminal/tool links are data, not commands.
- **Verify/accept:** wrong project/worktree target, malicious URLs/schemes, huge paste/files, selection fidelity/security scope, cancellation; no surprise secrets on pasteboard or arbitrary launch.
- **Non-goals:** duplicating attachment affordances or silent broad filesystem access.

### N07 — Restoration and local migration integration · S after F08/T02/J06, N03 if accepted

- **Scope/outcome:** `App/Restoration/`, local schema/tests; restore windows/views/tabs/drafts/scroll safely, missing/unavailable backend entities recover visibly.
- **Contract:** versioned local preference data → local restored navigation followed by authoritative hydration, never stored conversation facts.
- **Verify/accept:** interrupted write/corruption/older/newer schema, missing location/session, cold launch offline, same session multiwindow rules; restoration never sends a prompt or stops/starts execution implicitly.
- **Non-goals:** backend DB migration or hidden local transcript cache as truth.

### N08 — Threat model and security remediation gate · S review after relevant integrations

- **Scope/outcome:** `docs/security.md`, read-only audit plus findings assigned to feature owners; service credentials, secrets/logs/URLs/attachments/terminal/plugin/native permissions/process lifecycle assessed.
- **Contract:** local-first trust model and selected distribution/sandbox needs → verified safeguards; remote remains absent unless explicitly approved separate branch for TLS/certificate/credential/origin rules.
- **Verify/accept:** redaction/redirect/origin/token/pasteboard tests, no credential in UI prefs/fixtures/crash diagnostics, sandbox/service/file access feasibility demonstrated. Findings resolved before release, not buried in checklist.
- **Non-goals:** blanket “secure” assertion or changing backend config/permissions to ease tests.

### N09 — Measured performance and retention · P after functional baseline

- **Scope/outcome:** `Tests/Performance/`, profiling notes; agree transcript sizes, concurrent roots/children/projects, event bursts, memory, render responsiveness and reconnect scenarios with user.
- **Contract:** actual baseline measurements → budgets/regression tests and one owned optimization assignment at a time; session eviction/resync maintains correctness.
- **Verify/accept:** measured main-thread/UI latency and memory, bounded queues/caches/render parsing, no missed blockers/dropped correctness-critical updates; VoiceOver responsiveness and terminal included.
- **Non-goals:** invented benchmark claims, speculative optimization or infinite hydration/cache growth.

### N10 — Backend compatibility and upgrade matrix · P after exercised feature contracts

- **Scope/outcome:** `docs/compatibility.md`, contract/drift/upgrade tests; supported pinned release(s), prospective release check and clear incompatible state.
- **Contract:** schema/version fingerprint and operation fixtures → explicit support policy, unknown-safe behavior where safe and incompatibility where not.
- **Verify/accept:** candidate version contract differences, unsupported responses, local schema migration and reconnect after service replacement; no unauthenticated legacy fallback or silently latest support.
- **Non-goals:** downgrading server or modifying its DB/registration to satisfy test.

### N11 — Distribution channel/sandbox/installation proof · S after N08 decisions

- **Scope/outcome:** release configuration, entitlement/build settings owner and `docs/release.md`; choose direct distribution/store scope, architecture(s), installation/dependency detection and sandbox strategy.
- **Contract:** selected channel/security/OS constraints → reproducible app bundle and install/uninstall behavior that doesn't delete OpenCode data.
- **Verify/accept:** clean machine/account install, missing OpenCode guidance, permissions/file picker/service/helper feasibility, bundle resources and documented actual build commands.
- **Non-goals:** claiming store viability or sandbox exemption without proof, bundling backend implicitly.
- **Release-plan link:** choose the channel and archive/export model before prescribing archive commands; then execute the clean-install checks in [Release binary validation](release-binary-validation.md).

### N12 — Signing/notarization/release artifact · S after N11

- **Scope/outcome:** protected signing pipeline/documentation; Developer ID/notarization/stapling or chosen store path with credentials outside repo.
- **Contract:** approved channel/identity → verifiable signed artifact/checks and secure failure behavior.
- **Verify/accept:** actual signature/notarization/Gatekeeper/installation checks when credentials available; otherwise explicitly blocked, not claimed complete. No signing keys/tokens in files/logs.
- **Non-goals:** publishing without authorization or inventing successful notarization result.
- **Release-plan link:** signing/notarization/Gatekeeper evidence is blocked without an authorized identity and credentials; record it only as described in [Release binary validation](release-binary-validation.md).

### N13 — Update/rollback/channel policy · S after N11/N12

- **Scope/outcome:** release update mechanism/policy, integrity and migration notes; automatic updater only if approved, otherwise documented manual update path.
- **Contract:** selected channel → authenticated artifact delivery, compatibility checks and recoverable local-preference migration; backend install/update distinct.
- **Verify/accept:** approved update success/failure/interruption, old-local-schema launch, integrity/tamper rejection; preserve sessions/data, never silently update shared backend.
- **Non-goals:** claiming auto-updates when only manual path exists or unrequested network updater deployment.
- **Release-plan link:** validate update interruption, integrity, rollback and data preservation through [Release binary validation](release-binary-validation.md).

### N14 — Final parity and release gate · S last

- **Scope/outcome:** integrator updates inventory/worklog/release checklist and inspects full accepted changes. Resolve each agreed TUI user workflow or user-approved alternative/exclusion.
- **Contract:** all gates/decisions/evidence → truthful supported release and capabilities statement. Newly discovered missing feature requires new bounded slice(s), not optimistic gate closure.
- **Verify/accept:** P0–P5, accepted 6A–6G checks; TUI coexistence, service lifetime, roots/children/projects/windows, permission/form external settlement, unknown mutations, paging/races/overflow/reconnect, auth/files/review/PTY/plugin cases, security/performance/distribution evidence. Record precise blockers when checks cannot run.
- **Non-goals:** parity with every future release, arbitrary terminal JSX, every API endpoint or “complete” based only on screenshots.
- **Release-plan link:** N14 consumes final artifact and workflow evidence from [Release binary validation](release-binary-validation.md), not a Release compile alone.
