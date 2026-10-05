# Phase 6F — Plugin interoperability without impossible promises

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** pinned extension contracts and agreed parity inventory. **Exit 6F:** server plugin operations work where declared; unchanged representative terminal plugin behavior is tested; user chooses a support subset/bridge/isolated terminal fallback/native adaptation or approved exclusion.

**Non-goals:** promising arbitrary OpenTUI/Solid JSX becomes SwiftUI, embedding a terminal as the main app architecture, unrestricted native plugin privileges or delaying a working client indefinitely for infeasible parity.

**Waves:** X01 → X02 → user decision → X03. No speculative bridge worker before decision. Research/prototypes are isolated and can occur alongside independent feature families. Server plugins remain backend-owned; the native client need not host them just to observe their effects.

### X01 — Server plugin status and declared RPC · S

- **Scope/outcome:** `API/Plugins/RPC/`, `Features/Plugins/`; inventory/status and supported method/event bindings using imported/shared schema evidence or explicit generic RPC contract.
- **Contract/dependencies:** verified plugin/RPC definitions, explicit location/auth/error envelope and stream semantics; D09 resolved config read.
- **Verify/accept:** approved disposable plugin method/event, unknown method, auth/backend errors and reconnect; unknown events safe, no automatic call of discovered arbitrary methods. Plugin update/check UI needs separately approved semantics.
- **Non-goals:** terminal UI compatibility or loading JS merely to make ordinary HTTP RPC call.

### X02 — Representative unchanged TUI-plugin trials · S after X01

- **Scope/outcome:** `docs/tui_plugin_trials.md`, isolated test specimens; unchanged command registration, toast, rendering slot, JSX dialog/panel and server-RPC samples.
- **Contract:** pinned TUI plugin API → reproducible pass/fail/unsupported matrix for candidate approaches: native backend access, JS bridge, actual terminal host, native adaptation.
- **Verify/accept:** document dependencies, security/storage/lifecycle/rendering limits and actual trials; no success extrapolated from RPC to arbitrary rendering. Obtain user decision on scope/cost before implementation.
- **Non-goals:** multiple windows unrelated to plugins, production compatibility from a toy mock or generic JSX translation promise.

### X03 — One approved compatibility boundary · S after X02 decision

- **Scope/outcome:** narrowly isolated bridge/native extension/terminal-host boundary and support matrix, or documented approved exclusion with no runtime code.
- **Contract:** selected subset → explicit command/navigation/notification/storage/failure/security capabilities; arbitrary API denied by default.
- **Verify/accept:** chosen unchanged samples pass where promised; unsupported slots/JSX fail clearly; crash/timeout/unload/reconnect cannot destabilize ordinary threads. If strategy requires several adapters, assign one new bounded slice per declared capability rather than a whole host in one assignment.
- **Non-goals:** full terminal renderer/native view translation engine or silent installation of additional runtime.

**6F gate:** proven scope plus user-approved unsupported cases enters parity inventory. Keep ordinary session/tool behavior stable with backend plugins enabled; optional terminal fallback is explicitly a compatibility surface, not Joycode's core UI.
