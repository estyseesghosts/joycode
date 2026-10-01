# Phase 6A — Advanced composer and input

[Roadmap](README.md) · [Verification](verification-and-coverage.md)

**Entry:** P5 and verified feature-specific payloads. **Exit 6A:** approved attachments/references/commands/skills/history/completion/steering/inbox workflows work with draft recovery, correct location and no duplicate unknown submission.

**Non-goals:** client scheduling/durable execution queue, invented attachment shapes, shell execution by completion, arbitrary file access without consent.

**Waves:** A01 contracts first; A02/A03 use separate UI areas, A04 follows insertion interface freeze. A05/A06 independent discovery/execution adapters after completion contract. A07 delivery semantics → A08 inbox controls. Composer shared integration is one owner; do not concurrently rewrite its central editor. Optional NSTextView bridge gets a separate bounded assignment if TextEditor fails tested IME/selection/attachment needs.

### A01 — Attachment payload/security contract · S

- **Scope/outcome:** `Domain/ComposerAttachment/`, `API/Prompt/Attachments/`; exact supported file/image/agent/skill types, size/MIME/source/path/base64 rules and consent policy.
- **Contract/dependencies:** pinned prompt schema, approved file-access strategy; R12 unknown outcome and V08 composition.
- **Verify/accept:** accepted/rejected/corrupt/oversized fixtures and live supported attachment; cross-location paths cannot silently refer to wrong project; rejected upload preserves draft.
- **Non-goals:** old report format guesses, broad permission grant or rendering all types before verified support.

### A02 — Attachment picker/paste/drop lifecycle · P after A01

- **Scope/outcome:** `Features/Composer/Attachments/`; single attachment bubble becomes functional, previews/remove/progress/validation, file/image paste/drop.
- **Contract:** typed draft attachments → accepted submission source, cancellation/cleanup, clearly invalid items.
- **Verify/accept:** canceled picker/oversize/drop/paste, lifecycle after restart and session switch, temporary file cleanup/security scope; one live file/image prompt reaches correct backend context.
- **Non-goals:** second plus/paperclip action or showing accepted before server confirmation.

### A03 — File/directory references and line ranges · P after A01

- **Scope/outcome:** `Features/Composer/References/`, scoped adapters; discover/select references and insert verified typed source/range metadata.
- **Contract:** scoped path/reference catalog → shared insertion token/action protocol frozen before A04.
- **Verify/accept:** spaces/Unicode/escaping, invalid line range, deleted file, worktree switch and mismatch; no guessed `@` text when typed source required.
- **Non-goals:** sending whole directory blindly, direct file modification or assuming file-find is content search.

### A04 — Completion and private prompt recall · S after A03 insertion freeze

- **Scope/outcome:** `Features/Composer/Completion/`, `State/PromptHistory/`; contextual candidates for supported paths/agents/commands/skills and privacy-aware local recall.
- **Contract:** editor caret/query + available catalogs → cancelable choices/insertion, local recall distinguished from authoritative conversation history.
- **Verify/accept:** stale completion cancellation, Unicode/IME/caret/multiline, keyboard accept/escape, project-scoped history/privacy settings; choosing candidate never sends automatically.
- **Non-goals:** separate server conversation DB or shell command execution on completion.

### A05 — Slash/custom commands · P after A04

- **Scope/outcome:** commands adapter and composer command UI; list, argument entry, supported session invocation and error/result rendering.
- **Contract:** official command inventory → documented command mutation or separately classified client-native action.
- **Verify/accept:** custom/unknown/unavailable command, arguments, live result/TUI comparison; normal prompt not mislabeled as dedicated command.
- **Non-goals:** reimplementing terminal-only commands without documented native alternative.

### A06 — Skill/reference catalog and invocation · P after A04

- **Scope/outcome:** skill/reference adapters, `Features/Composer/Skills/`; discovery and supported attachment/activation path.
- **Contract:** pinned skill/reference definitions → correct location and invocation. Experimental activation needs approval.
- **Verify/accept:** unavailable skill, changing config, correct location, live history reflects use; references distinguish catalog content from arbitrary file attachment.
- **Non-goals:** local skill runtime, installation editor or guessed activation route.

### A07 — Steer active execution · S after A05/A06

- **Scope/outcome:** delivery action and `Features/Composer/Steer/`; explicit active-run steering where supported, distinct from normal idle send.
- **Contract:** verified prompt/inbox delivery semantics → server-owned insertion/status. Only enable in supported execution states.
- **Verify/accept:** live active session/child steering, busy conflicts/response loss, repeated-click guard and context retention; no duplicate unknown delivery.
- **Non-goals:** frontend scheduler or universally available steering assumption.

### A08 — Queue/inbox inspect, edit, cancel · S after A07

- **Scope/outcome:** inbox adapter and `Features/Composer/Queue/`; authoritative queued items, supported update/cancel and delivery status.
- **Contract:** server inbox identity/state → correct steer-vs-queue controls and reconnection snapshot.
- **Verify/accept:** queue while busy, navigate away/reopen, cancel/edit pending item, item settled elsewhere, reconnect/unknown reply; delivered input not resubmitted.
- **Non-goals:** durable client execution queue or claiming canceled merely from local removal.

**6A gate:** integrate shared composer once, rerun P1–P5, demonstrate supported input families and busy delivery alongside TUI; inventory unsupported capabilities explicitly, preserve drafts and privacy through failures.
