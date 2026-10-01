# Phase 6D — Models, authentication, MCP and configuration

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** P5, current feature contracts and credential threat model. **Exit 6D:** discovered models/variants, supported connection methods, credential lifecycle, MCP/resource status and safe approved configuration workflows function without exposing secrets or rewriting unrelated settings.

**Non-goals:** local provider/MCP runtime, raw secrets in preferences, assuming all integrations have API keys/OAuth, global patch presented as arbitrary project-config write, client config parser as alternate authority.

**Waves:** D01 and D07 independent catalog reads; D02 and D03 separate model/auth areas. D04/D05 attempt lifecycles consume frozen method types; D06 credential management separate after credential identity freeze. D08 follows MCP reads; D09 read configuration; D10 mutation decision then D11 gate. Shared settings navigation/composition edited by integrator only.

### D01 — Provider/model catalog and defaults · P

- **Scope/outcome:** provider/model adapters, `Features/Models/Catalog/`; capabilities, connected availability and server defaults with search/filter states.
- **Contract:** actual model/provider/integration distinctions → discovered entries/selection constraints.
- **Verify/accept:** disconnected/disappearing model, inherited/default changes, stale catalog selection; no hardcoded provider list or accepted selection on failed switch.
- **Non-goals:** guessed cost/capability support or authentication in same slice.

### D02 — Variants and session model settings · S after D01

- **Scope/outcome:** `Features/Models/Variants/`, switch adapter; supported variant/settings choices and truthful current session state.
- **Contract:** exact model/variant compatibility → documented switch/selection payload; local preferred choice distinct from backend current fact.
- **Verify/accept:** unsupported variant disabled, model/agent switch preserves valid selection, transcript/TUI reflect accepted change, busy/error/unknown outcome reconciles.
- **Non-goals:** inferred reasoning levels or cost math not in contract.

### D03 — Method discovery and key connection · P after D01 types

- **Scope/outcome:** integrations adapter and `Features/Integrations/KeyConnect/`; discover actual auth methods, secure secret entry and server key-connect result.
- **Contract:** integration method definition → correct prompt/input, no credentials persisted in UI prefs/logs.
- **Verify/accept:** valid/invalid/canceled input, secure field/copy/privacy, connected refresh and redacted errors; method absent means absent control.
- **Non-goals:** requesting API key for an OAuth-only integration or new local credential DB.

### D04 — OAuth attempt lifecycle · S after D03 method freeze

- **Scope/outcome:** `Features/Integrations/OAuth/`, attempt adapter; start/system browser/status/complete where required/cancel/expiry and safe recovery.
- **Contract:** verified attempt/callback model → whitelisted safe URL handoff and server-owned credential result. Check redirect/trust, don't invent local callback port.
- **Verify/accept:** success/denial/expiry/cancel, app background/restart, stale polling response, browser URL safety; no stuck spinner or credential leak.
- **Non-goals:** untrusted embedded auth WebView or logging returned tokens.

### D05 — Command-based connection attempts · P after D03 attempt contract

- **Scope/outcome:** command-connect adapter and `Features/Integrations/CommandConnect/`; supported server start/status/cancel/recover.
- **Contract:** method definition + server attempt → result/status, no arbitrary local auth shell execution.
- **Verify/accept:** cancellation/recovery/timeout/failure, command method unavailable, secret redaction and authoritative connection refresh.
- **Non-goals:** credential management or local `Process` executing untrusted command. May overlap D04 only with separate attempt stores/interfaces.

### D06 — Credential activation/update/remove · P after D03 credential freeze

- **Scope/outcome:** credential adapter and `Features/Credentials/`; inventory permitted metadata and confirmed lifecycle actions.
- **Contract:** actual credential IDs/mutation rules → activation/update/removal with scope/consequence disclosure and R12 reconciliation.
- **Verify/accept:** failed/ambiguous mutation, confirmation cancel, changing active credential reflected in server/TUI, no raw-secret redisplay without documented need.
- **Non-goals:** command connection bundled into this assignment or local secret persistence. Disjoint files from D04/D05.

### D07 — MCP status/resources/templates · P

- **Scope/outcome:** MCP read adapter and `Features/MCP/Catalog/`; connected/disabled/pending/failed/needs-auth states, resource/template catalog and supported resource selection.
- **Contract:** verified catalog/location metadata → source-aware browsing; resource reading/attachment requires supported path or explicitly recorded gap.
- **Verify/accept:** large/stale catalog, auth needed, unavailable resource and scoped reconnect refresh; browsing doesn't secretly start another MCP runtime.
- **Non-goals:** direct client external MCP connections or assumed resource read endpoint.

### D08 — Approved MCP lifecycle mutations · S after D07

- **Scope/outcome:** MCP mutation adapter/UI; add/connect/disconnect/remove where contract/product approval permits, separate auth handoff using D03–D05 where supported.
- **Contract:** verified experimental scopes → explicit action and authoritative refresh; no manual config rewrite.
- **Verify/accept:** disposable test config, already-connected/deleted state, ambiguous reply, supported consent/auth steps; absent operation hidden/disabled honestly.
- **Non-goals:** uncontrolled installation or permanent autoallow workaround.

### D09 — Resolved OpenCode configuration read · S after D01/D07

- **Scope/outcome:** config read adapter and `Features/Settings/OpenCodeConfig/`; resolved location settings, available shells and source/inheritance only if contract supplies it.
- **Contract:** backend resolved document → clearly distinguished OpenCode vs client preferences. Don't invent per-field provenance absent API.
- **Verify/accept:** project/global changes from TUI reflected after supported reload, read-only state useful, inaccessible values/errors sanitized.
- **Non-goals:** parsing/writing global/project files independently or presenting global patch as project write.

### D10 — Safe writable configuration scope · S after D09, approval gated

- **Scope/outcome:** narrow verified mutation/reload adapter and editing UI, or documented read-only decision when required scope unavailable.
- **Contract:** approved exact writable scope (currently documented global experimental patch must be checked) → preserve unrelated entries, validate conflicts/errors and refresh resolved state.
- **Verify/accept:** disposable configuration mutation, concurrent external edits/unknown response, reload effects and active-session consequences documented; no unrequested service/config reset.
- **Non-goals:** wholesale rewrite or claiming fully supported project editor if no backend route.

### D11 — 6D integration gate · S

- **Scope/outcome:** integrator settings/catalog composition and evidence record; owner fixes security/cross-context findings.
- **Verify/accept:** supported key/OAuth/command paths, variants, credential action, MCP status/auth/resource and approved config mutation demonstrate real backend agreement; earlier gates retained. Unsupported methods/scopes explicitly dispositioned.
- **Non-goals:** fake connected badges, testing real user credentials destructively or claiming all integrations verified from one sample.
