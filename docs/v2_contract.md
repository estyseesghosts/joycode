# OpenCode V2 contract (F01)

**Status:** documentation-only research record. This is the contract target for Joycode's
macOS 26 client; it is not a live-gate record. No provider call, service registration,
configuration, or database was changed while producing this document.

## 1. Pinned provenance

The selected release is **OpenCode v2.0.20**. The official tag resolves to commit
`84c9be93a56304a108f1a22df0c5d62c26d5b6ca`:

- Release/tag: [v2.0.20](https://github.com/anomalyco/opencode/releases/tag/v2.0.20)
- Pinned source tree: [commit 84c9be9](https://github.com/anomalyco/opencode/tree/84c9be93a56304a108f1a22df0c5d62c26d5b6ca)
- OpenAPI source, Git blob `7ca75e0ec9bc8994bf0d8e74d4b684739f63923e`:
  [packages/protocol/openapi.json](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/protocol/openapi.json)
- Generated promise client:
  [packages/client/src/promise/generated/client.ts](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/client/src/promise/generated/client.ts)
- Promise service wrapper:
  [packages/client/src/promise/service.ts](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/client/src/promise/service.ts)

The generated client and service wrapper are pinned to the same source revision above.
The official TUI uses this generated client/service path; it is reference evidence, not
permission to copy backend orchestration into Joycode. The OpenAPI blob and generated
sources are the authority below. A historical researcher report is not evidence.

## 2. Evidence and approval states

* **Exact contract evidence:** operation names, paths, parameters, body fields, response
  shapes, and status meanings recorded from the pinned OpenAPI/client sources above.
   * **Implementation status (2026-10-01):** F02–F09 implementation and focused verification exist;
   Phase 0/F10 is complete for its defined inventory, contract, fixture, narrow live-evidence
   and test-result gate. Contract/live proof and operation-specific evidence
  remain subject to the [deferred-work ledger](plan/deferred-work.md).
  * **Approval and evidence scope:** on 2026-10-01 the user first approved a non-mutating
   disposable-context scenario including authenticated `GET /api/info`, one cancellable SSE
    stream, and official-TUI/Joycode observation. That scenario was exercised in the approved
    disposable sandbox. The user
   later explicitly authorized a read-only check of their already-running localhost service at
   port 49374. That limited probe succeeded against OpenCode `2.0.21` (off the pinned `2.0.20`
   target): `/api/info` returned matching registered/reported version and PID, and `/api/event`
   delivered the initial `server.connected` event before the client closed the stream. See the
    [sanitized live-check record](plan/live-check-2026-10-01.md). The pinned sandbox was fully
    cleaned up; this does not authorize touching the
   existing service. Provider calls, user-service setup/registration/database changes, and
   session mutations outside the disposable sandbox remain excluded.
  * **Not proved:** the narrow pinned endpoint/stream probe does not establish broad workflow
    parity, permission,
    form, prompt, and session behavior. See [deferred work](plan/deferred-work.md).

## 3. Connection, context, and local service boundary

### HTTP context and authentication

For operations whose contract accepts location context, requests are scoped with the
OpenCode `location` deep-object query, encoded as `location[directory]`. The transport
must preserve that scope explicitly rather than silently using a global working directory.
Other operation context is endpoint-specific, as detailed in the operation ledger (§4):
server-scoped operations, default-context project discovery, the session-create body, or
pinned session context. The service registration's Basic username is
`opencode`; the password is the registered service password when one is present. Never
log, display, or put that password in fixtures.

The server-information operation is **`GET /api/info`** (no mutation). Its pinned
operation definition is in the [OpenAPI source](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/protocol/openapi.json).
It is the required approved probe for server/version compatibility; it does not by
itself prove that a local binary came from the pinned release.

### Registration, discovery, and ensure

The local registration file is `~/.local/state/opencode/service.json`, or the equivalent
path under `XDG_STATE_HOME`. Its registration object requires `url` and `pid`; `id`,
`version`, and `password` are optional. The file permissions must be `0600`. Passive
discovery is read-only.

Native **ensure** must be a separate, visibly mutating capability. It can probe
`GET /api/info`, reuse a ready service, start `opencode serve --service` when missing, or
replace and stop an incompatible service. Repeated probe timeouts (three) can clear PTY
handoff and terminate the incumbent; PTY handoff may call an experimental endpoint and
clear terminals. Thus ensure is **unsafe for app launch** and must not be invoked by Joycode
as lookup or connection setup. Under the current decision, F07-R remains passive/read-only
and app-managed startup is deferred for explicit R01 revisit. Verify the exact behavior in
the pinned [service source](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/client/src/promise/service.ts),
   [service-version source](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/client/src/service-version.ts),
   and [PTY handoff source](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/client/src/pty-handoff.ts)
before any future implementation and obtain approval for a disposable local run. **Unknown:**
this document does not authorize or prove a safe native ensure policy. App exit must not
stop a shared service.

Version matching is explicit: when registration `version` is present, passive Promise
discovery requires exact equality with `/api/info.version`; when it is absent, no
registration-version comparison occurs. With no requested version constraint, discovery
accepts any valid server regardless of whether registration `version` is present. An exact
requested version constraint must match the probed server version. Discovery is passive
read/probe only. Binary provenance and provider approval remain unproved.

## 4. Phase 0/1 operation ledger

Every row is an initial client operation, not a claim that the operation has run here.
The path, method, context, fields, response and errors are the exact pinned inventory.
Context is explicit: location middleware applies to `/api/location`, `/api/agent`,
`/api/model`, and global permission/form lists; `/api/project` has no query but uses the
backend default context; session creation carries `location` in its body and absent means
server cwd; session listing is cross-session and filters `directory`, `project`, and
`subpath`; session-specific operations resolve the pinned session location. Joycode must
never accidentally rely on server cwd.

The `session.move` entry below is a **source-only pinned contract** from v2.0.20; it is
not live validation and does not imply that Joycode supports the operation. The pinned
[`OpenAPI operation`](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/protocol/openapi.json#L1857-L1943)
and [generated client](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/client/src/promise/generated/client.ts#L699-L710)
are authoritative for the HTTP shape. The protocol operation list
omits the declared `401 UnauthorizedError`; runtime authentication behavior was not
checked live. On the server, the destination is resolved relative to the current
session directory, must already exist, and is mapped into project/subpath/location
context by the [handler](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/server/src/handlers/session.ts#L280-L302)
and [move core](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/core/src/session/move.ts#L74-L100).
A successful move produces a `session.moved` projection update to directory, subpath,
project, and update time ([projector](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/core/src/session/projector.ts#L466-L481)).
The TUI workflow evidence is [here](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/tui/src/component/prompt/index.tsx#L270-L312).
These are source findings, not client guarantees.

| Operation | Exact request/context and success response | Declared errors |
|---|---|---|
| Server info | `GET /api/info`; no context. `200 ServerInfo`. | `400 InvalidRequestError`; `401 UnauthorizedError`. |
| Location discovery | `GET /api/location`; optional `location[directory]`. `200 Location.PublicInfo`. | `400 InvalidRequestError`; `401 UnauthorizedError`. |
| Project discovery | `GET /api/project`; no params, backend default context. `200 Project[]`. | `400 InvalidRequestError`; `401 UnauthorizedError`. |
| Agent discovery | `GET /api/agent`; optional location. `200 {location,data: Agent.Info[]}`. | `400 InvalidRequestError`; `401 UnauthorizedError`. |
| Model discovery | `GET /api/model`; optional location. `200 {location,data: Model.Info[]}`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `503 ServiceUnavailableError`. |
| Session list | `GET /api/session`; `limit,order,search,parentID,directory,project,subpath,cursor`; newest 50 default. `200 {data: Session.Info[], cursor: previous?/next?}`. | `400 InvalidCursor` or `InvalidRequest`; `401 UnauthorizedError`. |
| Session create | `POST /api/session`; body `id,title,agent,model,location,metadata,permissions`. `200 {data: Session.Info}`. | `400 InvalidRequestError`; `401 UnauthorizedError`. |
| Session read | `GET /api/session/{sessionID}`; pinned session context. `200 {data: Session.Info}`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound`. |
| Session update | `PATCH /api/session/{sessionID}`; body `title,metadata,permissions`; pinned context. `204`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound`. |
| Session move | `POST /api/session/{sessionID}/move`; body requires `directory: string` and may include nullable `delivery: "steer" | "queue"`; no query, `location`, or `workspaceID` field. `204`. | `400 InvalidRequestError`; `401 UnauthorizedError` (declared by OpenAPI; omitted from the protocol operation list and not runtime-auth validated); `404 SessionNotFound`. |
| Agent/model selection | `POST /api/session/{id}/agent` body `{agent}` or `/model` body `{model: Model.Ref}`; pinned context. `204`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound`. |
| Prompt | `POST /api/session/{id}/prompt`; body `text` plus optional `id,files,agents,skills,metadata,delivery,resume`; pinned context. `200 {data: Session.Inbox.User}`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound`; `409 Conflict`. |
| Interrupt | `POST /api/session/{id}/interrupt`; optional `resume`; pinned context. `200 {interrupted: boolean}`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound`. |
| Message history | `GET /api/session/{id}/message`; `limit,order,cursor,type`; pinned context. `200 {data: Session.Message.Info[], cursor: previous?/next?}`. | `400 InvalidCursor` or `InvalidRequest`; `401 UnauthorizedError`; `404 SessionNotFound`; `500 UnknownError`. |
| Events | `GET /api/event`; authenticated `text/event-stream`; `200` stream. | `400 InvalidRequestError`; `401 UnauthorizedError`; stream `SubscriberOverflowError` or encoding failure (not HTTP 409). |
| Global permission list | `GET /api/permission/request`; location middleware. `200 {location,data: Permission.Request[]}`. | `400 InvalidRequestError`; `401 UnauthorizedError`. |
| Session permission list | `GET /api/session/{id}/permission`; pinned context. `200 {data: Permission.Request[]}`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound`. |
| Permission reply | `POST /api/session/{id}/permission/{requestID}/reply`; `decision` once/always/reject, optional `message`; pinned context. `204`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound` or `PermissionNotFound`. No declared 409. |
| Global form list | `GET /api/form`; location middleware. `200 {location,data: Form.Info[]}`. | `400 InvalidRequestError`; `401 UnauthorizedError`. |
| Session form list | `GET /api/session/{id}/form`; pinned context. `200 {data: Form.Info[]}`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound`. |
| Form detail | `GET /api/session/{id}/form/{formID}`; pinned context. `200 {data: Form.Detail}`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound` or `FormNotFound`. |
| Form reply | `POST /api/session/{id}/form/{formID}/reply`; `{answer: Form.Answer}`; pinned context. `204`. | `400 FormInvalidAnswer` or `InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound` or `FormNotFound`; `409 FormAlreadySettled`. |
| Form cancel | `DELETE /api/session/{id}/form/{formID}`; pinned context. `204`. | `400 InvalidRequestError`; `401 UnauthorizedError`; `404 SessionNotFound` or `FormNotFound`; `409 FormAlreadySettled`. |

An experimental session export supports `sanitize=true`. Sanitization does **not** promise
complete or exact redaction; do not treat an export as safe fixture content without a
manual secret/path/prompt review. Its exact path and schema must be read from the pinned
[OpenAPI operation](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/protocol/openapi.json) before use.

## 5. Transcript and event wire notes

Message projections contain tagged assistant content: `text`, `reasoning`, and `tool`.
Tool states include `streaming`, `running`, `completed`, and `error`. Unknown tags must
survive as unknown-safe content rather than crash or be coerced into plain text. History
is paged as described above; no fabricated total order or exactly-once event guarantee is
allowed.

Native event envelopes contain `id`, `type`, finite `created`, and `data`, plus optional
`location` and `metadata`. Durable events additionally contain `durable` with
`aggregateID`, `seq >= 0`, and `version >= 1`; ephemeral events do not contain `durable`.
`server.connected` is special: its envelope is `id`, `type`, and `data: {}` (the handler
does not add `created`). The server handler prepends this marker. Events are global and
location-tagged where the envelope provides location; RPC events (`rpc.*`) require a
public-reference `location`.

The event endpoint emits only SSE frames `data: JSON\n\n`—there are no SSE `id:` or
`event:` lines—and heartbeat comments are `: heartbeat\n\n`.
The stream has no replay and no server reconnect protocol. One application-owned reader
must consume it; view remounts must not create readers. Each subscriber queue has capacity
4096. A full queue drops/fails that subscriber with `SubscriberOverflowError`; this is a
stream failure source, not HTTP 409. An encoding failure can fail all subscribers. These
envelope, framing, heartbeat and limit statements are sourced from the pinned:
[OpenAPI](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/protocol/openapi.json),
[event schema](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/schema/src/event.ts),
[event manifest](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/schema/src/event-manifest.ts),
[server event schema](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/schema/src/server-event.ts),
[event handler](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/server/src/handlers/event.ts),
[event feed](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/server/src/event-feed.ts),
[generated client](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/client/src/promise/generated/client.ts),
and [service](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/client/src/promise/service.ts).

Relevant event families are `permission.asked`, `permission.replied`, `form.created`,
`form.replied`, `form.cancelled`, and session/message/part/tool events. Exact event
envelopes and routing fields must be decoded from the pinned schema; unknown families are
not errors. The only live event observed so far is the initial `server.connected` marker from
the pinned `server.connected` marker; no session/business event or provider-dependent behavior
has been observed.

## 6. Acquisition checklist and boundary

Before F01 can be called live-verified, an approved operator must:

1. Record the exact scenario scope and approver/date for the planned operation before
   inspecting registration metadata, sending `/api/info`, or opening SSE. Keep provider
   calls under a separate explicit approval.
2. Acquire the v2.0.20 binary through an attributable official release path and record
   its provenance; do not infer binary identity from a registration version string.
3. In a disposable local setup, passively inspect registration metadata only (no edits),
   verify `0600`, and record sanitized registration mode/metadata without any password.
4. With the recorded approval, call `GET /api/info` and retain the exact request and a sanitized response proving server
   version/compatibility; this is the binary/release match gate.
5. Capture sanitized, provenance-tagged responses for info, session list/create/get,
   selection, history paging, prompt acceptance, interrupt, permission and form flows.
6. Capture raw SSE framing including `server.connected`, heartbeat, one location-tagged
   event, cancellation, and an explicitly synthetic parser-overflow case. Do not claim
   synthetic overflow is live evidence.
7. Review exports manually; `sanitize=true` is not a complete-redaction guarantee. Remove
   credentials, private paths, prompt text, provider data, and identifiers before adding
   any future fixture. **No fixture content is added by F01.**
8. Record exact status/body/error observations and approval owner/date next to each fixture.

Operation-specific capture owners must include R01, R03 (location and project discovery),
B09 (`session.move`, only with user approval), and R04–R11 as applicable. Synthetic-only
fixtures do not close live evidence.

Joycode owns presentation, local interaction, and synchronization state. OpenCode remains
authoritative for agent execution, sessions, persistence, tools, permissions, forms, and
service behavior. The client must not recreate orchestration, permission policy, or session
persistence, and must not use service ensure as an implicit discovery operation.

## 7. Checks

No established documentation checker is present in the starting repository. No
documentation check was run in this documentation-only slice. Phase 0's narrow pinned
connection/event evidence is recorded, but F01's broader operation-specific live verification
and all later workflow/release gates remain open. No provider or session mutation occurred.
