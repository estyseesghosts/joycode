# R06/R07 pinned contract preparation (source only)

Re-read on 2026-10-05 from official v2.0.20 commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`, [OpenAPI](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/protocol/openapi.json). Preparation only, not implementation or acceptance.

## R06

`POST /api/session/{sessionID}/prompt` has required `text`; optional `id` (`^msg_`), files, agents, skills, metadata, delivery, resume. **No primary agent/model fields**: these are selected on the session with the R05 operations. Success is exactly `200 {data: Session.Inbox.User}` (durable admission, not completed assistant output). Declared errors: 400/401/404/409. No blind retry or inferred idempotency guarantee.

The returned user inbox item requires `id`, `sessionID`, `time.created`, `type:"user"`, `payload` (required `text`) and `delivery` (`steer|queue`). This differs from a user **history message**, whose text is directly on the message and whose schema does not contain sessionID. Validate result identity before clearing a draft. Unknown transport/malformed success must retain the original draft/context. Cancellation after dispatch cannot prove rejection.

### Prompt identity and later read reconciliation

Primary source verification (no live calls): pinned `packages/core/src/session/session.ts:146–178` uses the supplied message ID, checks `admission.reconcile` for the same session/type, prepares only when no existing record is found, admits durable input, then wakes execution unless resume=false. `packages/core/src/session/inbox.ts:154–167` returns the first matching admission or promoted message for that ID and rejects session/type collision. This is pinned source behavior, not a general idempotency/retry guarantee; repeated POST can wake execution and is not Joycode's recovery policy.

`packages/core/src/session/projector.ts:609–640` promotes user inbox payload into history using **the same input ID**. The pinned OpenAPI provides `GET /api/session/{sessionID}/inbox` → `200 {data: Session.Inbox.Info[]}` for durable undelivered work and `GET /api/session/{sessionID}/message/{messageID}` → `200 {data: Session.Message.Info}` for a message owned by that session (400/401/404 errors). Thus a positive matching ID/type/session plus matching original text on the same connection context can establish acceptance after a lost reply. Absence/404 cannot prove rejection: the input may still be in transit, promoted between reads, canceled or removed; no total ordering or negative-proof rule is assumed. R06 retains uncertainty without re-POST; R12 may add these explicit authoritative checks with the frozen original request identity/text/context.

## R07

`Session.Message.Info` is a tagged union of agent-switched, model-switched, location-switched, user, synthetic, system, skill, shell, assistant, compaction and idle records. It is not a legacy message-plus-parts envelope. Message ID and created time exist on history records; history context is the session-specific request. Preserve server page order and stable identity without inventing a cross-resource total order.

Assistant records require id/time/type/agent/model/content; model is `{id,providerID,variant?}`. Text/reasoning content requires `type` and `text`, not a part ID. Tool content requires `type:"tool"`, `id`, `name`, `state`, `time.created`; nested state uses `status` tags streaming/running/completed/error. Streaming input is a string; running input/metadata are objects; completed has input plus nonempty `Tool.Content`; error has input and structured error, with optional content/metadata. Assistant finish/error/retry fields are optional. Unknown/malformed variants need a visible safe fallback and must not erase known neighboring records.

## Event follow-up for R08 (not yet frozen)

Primary integration review clarification: `assistant.model` is **Model.Ref object** (`id`, `providerID`, optional `variant`), not a string. `tool.state` is a **nested object** discriminated by `status`; input, metadata, content and error belong within that state. New synthetic fixtures must use these actual shapes; tests do not override pinned contracts. Incorrect initial adapter shapes were returned for repair before verification.

The R08/R09 source-only research verified the bare `server.connected` marker (`data:{}`; no version/generation field), session-ID routing, `/api/session/active` process-owned execution map and `POST /api/session/{sessionID}/interrupt?resume=false` → `200 {interrupted:boolean}` (acceptance, asynchronous cleanup). No per-session status GET exists in the pinned contract. Public event subscription remains live-only; durable envelope sequence does **not** supply a comparable snapshot watermark. Primary **rejects** the researcher's suggested “durable events > snapshot” merge / snapshot-implied sequence / resetting high-water from the marker: no contract proves those rules. R08 must use request-local invalidation epochs and scoped authoritative resync, retaining tombstones conservatively, rather than inventing snapshot ordering or replay. This preparation does not freeze all R08 contracts or authorize live checks.

### Fresh R07 leaf verification refinements

The fresh R07 researcher re-verified the pinned message schema, generated client, `handlers/message.ts`, `core/session/store.ts`, history decoder and message updater. History defaults to **50 newest-first (`desc`)**, limits are 1…200, ordering is internal sequence (not exposed), not timestamp. Returned pages preserve requested order; do not re-sort by created time. Sending `cursor` together with `order` is rejected. Cursors are opaque and both next/previous are emitted on **every nonempty page**, including edges: an empty page terminates paging. A missing/deleted anchor can also yield an empty page; do not infer replay or stable anchors across revert.

Actual variant tags include `agent-switched`, `model-switched`, `location-switched` (not schema type names “AgentSelected” etc.). Text/reasoning lack IDs; positional keys belong to the full snapshot only. Tool keys are scoped tool IDs. Live ordinals are not persisted in history and cannot be assumed to equal array indices without separate R08 proof. Tool output is text `{type,text}` or file `{type,uri,mime,name?}`; structured persisted error requires `{type,message}`, optional status. Extra fields must be tolerated. User file attachments can embed base64 bytes; do not copy them into display/debug strings.

Pinned server history decoding is whole-page atomic: one invalid stored variant returns 500 UnknownError, not a partial valid page. Retaining known transcript on failure is a client requirement, not a server partial-page guarantee. For a future 2xx body, per-entry unknown-safe decoding should preserve raw variants and valid neighbors. None of this is live acceptance.

The pinned [session-event schema](https://github.com/anomalyco/opencode/blob/84c9be93a56304a108f1a22df0c5d62c26d5b6ca/packages/schema/src/session-event.ts) routes current events by `data.sessionID`; text/reasoning use assistantMessageID plus ordinal, tools use assistantMessageID plus tool id. Ephemeral deltas differ from durable full-value boundaries. The public manifest explicitly excludes replay-only `session.message.content.updated`. Do not implement guessed legacy part updates. R08 must separately verify reduction/race strategy and routing/version constraints before integration; stream replay and global ordering remain unsupported.

No existing-service, provider, session mutation or live capture was performed.
