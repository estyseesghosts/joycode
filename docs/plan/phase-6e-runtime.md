# Phase 6E — Shell, interactive PTY and runtime status

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** P5, verified scoped runtime contracts. **Exit 6E:** distinguish agent terminal-output cards, server shell jobs and real interactive PTY; approved terminal lifecycle works and runtime indicators have evidence.

**Non-goals:** local shell substitution, static logs labeled interactive terminal, client LSP runtime, mandatory experimental persistent PTY or arbitrary service ownership.

**Waves:** E01 shell adapter and E07 runtime-status research can overlap disjoint code/docs. E02 contract/component decision → E03 transport → E04 emulator → E05 lifecycle integration; E06 isolated experiment only after standard PTY works. Runtime security/terminal behavior gets dedicated review; shared frame/composition changes single-owned.

### E01 — Server-owned shell jobs and output · P

- **Scope/outcome:** shell adapter and `Features/Shell/Jobs/`; list/inspect/output, start/remove only explicit approved documented actions; wire V17 output card.
- **Contract:** location-scoped job lifecycle → current server status with bounded logs; distinguish manual shell job from agent tool output.
- **Verify/accept:** running/completed/error, concurrent jobs, long output, inactive project, cancellation/removal semantics and unknown outcomes; no local Process as substitute.
- **Non-goals:** full terminal emulation or guessed stop behavior from DELETE name.

### E02 — PTY protocol and native component decision · S

- **Scope/outcome:** `docs/pty_contract.md`, terminal abstraction; verify create/list/get/update/delete/connect-token/WebSocket frames and resize/input semantics, assess proven native emulator/library/license/deployment requirements.
- **Contract:** actual PTY framing/auth/token expiry/lifecycle → transport protocol and native surface inputs independent of window layout.
- **Verify/accept:** sanitized handshake/frame fixtures and decision evidence; credentials restricted to proper origin, no guessed binary encoding.
- **Non-goals:** coding emulator from scratch by default or treating terminal card as proof.

### E03 — PTY transport adapter · S after E02

- **Scope/outcome:** `API/PTY/`; HTTP lifecycle/token and WebSocket I/O/cancellation/error boundaries.
- **Contract:** E02 protocol → ordered verified frames and explicit connected/disconnected/expired state; token logging forbidden.
- **Verify/accept:** partial/binary/text framing as documented, auth/expiry/cancel, live approved server-owned connect; bounded buffers and no silent data loss.
- **Non-goals:** persistent PTY routes or UI terminal renderer.

### E04 — Native terminal surface · S after E03

- **Scope/outcome:** `Features/Terminal/`; proven emulation with AppKit bridge if needed, input, selection/copy/paste, scrollback, resize/focus inside frame.
- **Contract:** emulator abstraction + PTY transport → actual interactive server terminal; paste safety policy and accessibility limits documented.
- **Verify/accept:** ANSI/control sequences, alternate screen if supported, wide Unicode, interactive stdin, resize, scrollback and keyboard focus; reject unsafe terminal-driven URL/clipboard actions unless approved.
- **Non-goals:** plain SwiftUI Text styled as terminal, remote/local shell execution outside server.

### E05 — Terminal lifecycle/recovery/ownership · S after E04

- **Scope/outcome:** terminal session state integration; tab/frame selection separate from server PTY termination, close vs delete/interrupt explicit.
- **Contract:** actual reconnect/lifecycle capabilities → safe disconnected view, reconnect/snapshot only where supported; no replay claimed without protocol.
- **Verify/accept:** switch/close/reopen tab, app background, token expiry, service loss and explicit delete; no duplicate terminal, accidental termination or focus stealing while output arrives.
- **Non-goals:** app quit killing shared service or assuming terminal reconnect preserves screen if no snapshot support.

### E06 — Persistent PTY experiment/decision · S after E05, optional

- **Scope/outcome:** `docs/persistent_pty_decision.md`; isolated adapter/prototype only if approved, tested snapshot/read/handoff/token contracts.
- **Contract:** prototype route evidence → tested support boundary or approved exclusion, not dependency of ordinary PTY.
- **Verify/accept:** ownership/restart/reconnect/handoff in disposable instance if implemented; failures isolated from core client and unsupported behavior clear.
- **Non-goals:** production stability promise from experimental route listing or unbounded expansion.

### E07 — Runtime status evidence and read-only indicators · P

- **Scope/outcome:** `docs/runtime_status_contract.md`, `Features/Status/`; map TUI-visible LSP/formatter/task/test/plugin runtime indicators to actual exposed V2 data.
- **Contract:** current operations/events/tool outputs → provenance and refresh/stale state. Running tests/task progress use verified tool data, not invented todo/test API.
- **Verify/accept:** every production indicator has source/error/refresh behavior; missing LSP/formatter route explicitly recorded as blocker/decision, not legacy endpoint guess.
- **Non-goals:** client language servers/formatters or classifying every shell line as authoritative test status.

**6E gate:** approved shell and actual interactive terminal demo with input/output/resize/recovery; source-aware indicators, TUI/backend comparison and earlier gates. Persistent experiment disposition and terminal accessibility limitations are explicit.
