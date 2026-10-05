# R08–R11 contract preparation (source only)

Pin: OpenCode v2.0.20 `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`, `packages/protocol/openapi.json`, protocol groups, schema and server/core publish sites. Fresh leaf research; primary still owns final interface freeze. No live/service/provider checks, no acceptance claim.

## R08/R09

Public `/api/event` is live-only. `server.connected` has `{data:{}}`, no backend generation/version or snapshot watermark. Durable sequence cannot be compared to a history snapshot, which contains no sequence. Reject inferred “events always outrank snapshots” ordering; use local invalidation epochs, conservatively retained deletion knowledge and authoritative scoped resync. Ephemeral deltas are not replayable. `session.message.content.updated` is replay-only, excluded from the public manifest.

`GET /api/session/active` returns `{data:{[sessionID]:{type:"running"}}}` for process-owned active execution. There is no `/api/session/{id}/status` GET. `session.status` is an ephemeral event with session ID and idle/busy/retry status; Session.Info can hold terminal outcome and idle time. `POST /api/session/{id}/interrupt?resume=false` returns `200 {interrupted:boolean}`: accepted interruption of process-owned work, cleanup asynchronous; idle may be false. Silence/disconnect never proves stopped. Source details must be checked again when writing the reducer.

## R10 permissions

Session-scoped GET `/api/session/{id}/permission` → `200 {data: Permission.Request[]}` pending-only, and GET `.../permission/{requestID}` → `200 {data: Permission.Request}`. Required request fields: id, sessionID, action, resources:string[]; optional save, metadata, tool source and message. POST `.../permission/{requestID}/reply` body `{decision:"once"|"always"|"reject",message?}` →204; declared 400/401/404, **not 409**. P1 excludes permanent autoapproval; exposing `always` needs separate policy disposition.

A missing/repeated/wrong-session permission reply is 404, not proof the intended reply succeeded. Core reject can remove all same-session pending permissions; reread the list after any reply. No positive settled permission detail remains. **R10 pinned-source correction:** `permission.asked` uses `Request.fields`, including required ID; the earlier claim that its declaration omitted ID was incorrect. If ID is missing, invalidate/reread, never submit an anonymous approval. `permission.replied` uses `{sessionID,requestID,reply}`. Session permission endpoint declarations live in protocol `groups/permission.ts`.

## R11 forms/questions

Session GET `.../form` → pending `200 {data:Form.Info[]}`; GET `.../form/{formID}` → `200 {data:Form.Detail}` with state. POST `.../form/{formID}/reply` body `{answer:{[key]:string|number|boolean|string[]}}` →204; DELETE `.../form/{formID}` cancels →204. Reply/cancel declare 400/401/404/409; form conflicts have `_tag:FormAlreadySettledError` and matching ID. Absence does not prove settlement; detail `state.status=answered|cancelled` is positive evidence if available. Settled-detail cache retention is internal, not a promised recovery window.

Info requires id, sessionID, title, nonempty fields. Field types are string/number/integer/boolean/multiselect/external, not a V1 question endpoint. Common editable fields have key/title?/description?/required?/hidden?/when?. Constraints include string length/pattern/format/options/custom/default; numeric min/max/default; boolean default; multiselect options/min/max/custom/default. Conditional `when` entries use prior field key and eq/neq value, AND semantics. External requires URL and acknowledgement true, not an automatic navigation. Unknown/unsupported types or validation rules must block blind submission and explain the limitation.

V2 question tool creates forms (q0, q1… string or multiselect) with metadata kind=question; answer via form endpoints. Public events: `form.created` data `{form:Info}`, `form.replied` `{id,sessionID,answer}`, `form.cancelled` `{id,sessionID}`. There is no wire blocking flag or expired state. Form IDs are `frm_…`; form sessionID is plain string and can be internal `global` sentinel. P1 uses real active-session scope only, not undocumented global behavior.

## Still open

Primary must recheck exact DTO fields/errors at implementation time. No ordering, restart persistence, runtime auth, TUI settlement, or provider-driven blocker demonstration was verified. Unknown mutation classification and bounded reconnection remain R12/R13 responsibilities.
