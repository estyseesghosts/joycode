# Project guidance

## Work in slices

- Keep work incremental and independently verifiable. For longer efforts, decompose the goal into small, loosely coupled slices.
- Delegate one bounded slice to one fresh subagent. Start a new subagent for each task or slice; do not rely on old child-session context.
- Give each delegate a self-contained brief: goal, scope/files, constraints, acceptance criteria, dependencies, verification, and explicit non-goals.
- Parallelize only slices with clear boundaries and compatible contracts. Avoid concurrent edits to the same files; settle shared interfaces first.
- Keep subagents as leaf workers. The primary agent owns task decomposition, integration, conflict resolution, and final verification.
- Treat delegated work as unverified until its diff and reported checks have been inspected. Preserve unrelated user changes; do not reset or discard work to resolve conflicts.

## Project context

- `docs/opencode_client_architecture.md` describes the intended implementation sequence and architectural boundaries. `docs/opencode_client_design.md` describes the visual/interaction direction; `docs/*.png` are design references. Treat these as intent, not proof of current implementation, and check for later decisions or conflicts before relying on them.
- The project direction is a native macOS client for the existing OpenCode V2 service. OpenCode remains authoritative for agent execution, sessions, permissions, tools, and persistence; the client owns presentation and local interaction.
- Keep UI, application state, and service/API communication separated. Prefer native Swift and SwiftUI for the client, using AppKit where macOS window or text-editing behavior requires it.
- Verify OpenCode V2 endpoints, payloads, events, and service behavior against the official V2 contract or generated client. Do not invent or infer undocumented API behavior.

## Changes and verification

- Inspect the relevant code, docs, and existing changes before editing. Make the smallest coherent change; avoid unrelated cleanup and premature abstractions.
- Add or update focused tests for changed behavior. Follow commands already established by the repository; do not invent build/test commands when no project harness exists.
- Before handing work back, summarize changed areas, checks actually run, and unresolved assumptions or follow-up work. The primary agent performs final integration checks.
