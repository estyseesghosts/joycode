# Native OpenCode Client for macOS
## Incremental Implementation Plan
**Platform:** macOS  
**Language:** Swift  
**Interface:** SwiftUI, with AppKit where necessary  
**Backend:** Existing OpenCode V2 service  
**Status:** Initial project specification

---

# 1. Project Objective

Create a native macOS client for OpenCode V2.

The application should eventually provide the complete functionality of the official TUI, while taking advantage of native macOS capabilities.

This is a new OpenCode frontend, not a replacement backend, TUI wrapper, or fork of OpenCode.

The application must communicate with the existing OpenCode service. OpenCode remains responsible for:

- Agent execution and orchestration.
- Sessions and message persistence.
- Model and provider configuration.
- Authentication and integrations.
- Tool execution.
- Permission enforcement.
- Project and workspace management.
- Backend plugins.

The Swift application handles presentation, interaction, state synchronization, local preferences, and macOS integration.

## 1.1 Development philosophy

Development must be incremental.

Each stage must produce a usable application or an independently testable improvement to the previous stage.

The initial target is intentionally small:

**Open a project, start a session, select Build or Plan, send a prompt, observe execution, and receive a response.**

We then introduce subagents, followed by simultaneous sessions and tab management.

Advanced functionality is added only after these fundamental operations work reliably.

## 1.2 UI flexibility

The visual design is not yet finalized.

Do not make architectural assumptions about:

- Sidebar positioning.
- Horizontal versus vertical session tabs.
- Conversation bubble styling.
- Tool-output presentation.
- Inspector panels.
- Window arrangement.
- Navigation gestures.
- Typography or visual themes.

Implement simple temporary views during early development.

Views should consume application state rather than directly control OpenCode communication. This allows their replacement without rebuilding the underlying functionality.

The goal is to finalize the application behaviour before finalizing its appearance.

---

# 2. Architecture and Technical Boundaries

## 2.1 Communication model

The application uses OpenCode's HTTP API and live event stream.

The intended relationship is:

**SwiftUI → Application State → OpenCode API Client → OpenCode Service**

The service is authoritative. SwiftUI maintains a local representation of the service's state.

No model inference, agent execution, tool execution or permission evaluation should be reimplemented in Swift.

## 2.2 Native transport

Prefer a native Swift implementation based on:

- Foundation.
- URLSession.
- Codable.
- Swift Concurrency.
- AsyncSequence.
- SwiftUI Observation.

The OpenCode V2 TypeScript client is the reference implementation for API behaviour.

Do not embed a JavaScript runtime solely to make ordinary API requests.

An optional lightweight JavaScript helper may be considered for service discovery and startup if reproducing the official service-management contract natively becomes unnecessarily difficult.

Keep that helper separate from ordinary API communication.

## 2.3 Initial code organization

Use a small modular structure:

| Module | Responsibility |
|---|---|
| App | Application entry, windows and dependencies |
| Service | Backend discovery, startup and connection |
| API | HTTP requests, authentication and event decoding |
| Domain | OpenCode-facing data models |
| State | Sessions, synchronization and application state |
| Features | Individual SwiftUI feature implementations |
| Tests | Mock and live integration tests |

Do not prematurely split these into numerous Swift packages.

Introduce package boundaries when the implementation has a clear reason for them.

### Architectural requirements

1. Views must not construct arbitrary API requests.
2. Transport code must not know the interface layout.
3. Session state must exist independently of the currently displayed view.
4. All server operations must pass through a defined API boundary.
5. Unknown tool and message types must not crash the application.
6. There must be one clear owner for each live event subscription.
7. Shared state must not depend on a window remaining open.
8. Keep source files and functions focused. Do not continuously expand one coordinator to accommodate unrelated functionality.

This structure is important even when the initial application supports only one visible session.

---

# 3. Phase 0 — Research and Project Foundation

**Objective:** Establish a reliable communication contract before implementing application features.

This is a short investigation phase, not an excuse to design the entire application upfront.

## 3.1 Establish a development baseline

Choose one known working OpenCode V2 release.

Record:

- OpenCode version.
- API specification or generated client version.
- Supported macOS and Swift deployment targets.
- Relevant service-management behaviour.
- Expected agent and session data structures.

V2 remains subject to API changes. Avoid developing against undocumented assumptions or silently mixing V1 and V2 examples.

Maintain a small compatibility document that records changes affecting the Swift client.

## 3.2 Inspect the existing API

Investigate the exact operations required for:

- Service information and health.
- Project discovery.
- Session creation, retrieval and listing.
- Agent discovery and selection.
- Model discovery and selection.
- Prompt submission.
- Message history.
- Live event subscriptions.
- Session interruption.
- Permission requests and responses.

Use the official generated API reference and TypeScript client as the source of truth.

Do not manually invent endpoint names or request structures.

Create a minimal request/response test fixture for each operation that the first implementation requires.

## 3.3 Create the Xcode project

Create a native macOS SwiftUI application with the proposed module structure.

Initially use a simple development window containing connection information and diagnostic output.

Add:

- Unit-test target.
- Integration-test target.
- Basic structured logging.
- A documented development configuration.
- A minimum build/validation command.

Do not introduce a custom component library yet.

### Phase 0 completion criteria

- The application builds and launches.
- The OpenCode version is identified.
- Required API operations are documented.
- The expected response and event structures are understood.
- Transport code can be developed without depending on the final UI.

---

# 4. Phase 1 — Service Connectivity

**Objective:** Make the application a functional OpenCode client before introducing agent interaction.

## 4.1 Service discovery

**Current decision (present scope):** The startup behavior proposed below is deferred and
superseded for now by passive-only F07-R. The client must not call `Service.ensure` or
implicitly start a service. Revisit startup in R01 only if needed and with explicit approval;
the [deferred-work ledger](plan/deferred-work.md) is canonical. The general proposal below is
retained as architectural intent for future approval.

Implement a dedicated service manager.

On application launch:

1. Discover an existing compatible OpenCode service.
2. Validate its availability and version.
3. Retrieve the required connection information.
4. Authenticate.
5. Establish the API connection.
6. Expose the connection state to the application.

Do not assume that OpenCode always listens on port 4096.

Use the installed V2 release's service registration and discovery contract.

When necessary, start a compatible service using OpenCode's supported startup mechanism.

An existing service must not be killed or restarted simply because the SwiftUI client closes.

## 4.2 Connection state

Support the following internal states:

| State | Meaning |
|---|---|
| Disconnected | No active connection |
| Connecting | Establishing transport |
| Connected | Service available |
| Reconnecting | Recovering a lost connection |
| Incompatible | Unsupported backend version |
| Failed | Connection or authentication error |

Keep these states independent of their eventual visual representation.

## 4.3 Live event infrastructure

Implement the event stream immediately.

This should not be added as a patch after conversation support exists.

The event infrastructure must:

- Decode incoming events.
- Preserve event ordering.
- Route events to the correct state owner.
- Handle unexpected or unknown event types.
- Detect connection failure.
- Reconnect when possible.
- Fetch authoritative state after reconnection.
- Prevent duplicate active subscriptions.

OpenCode V2 subscriptions are live-only. Missed events cannot simply be replayed by reconnecting.

Therefore, synchronization must use both initial API snapshots and subsequent live events.

Do not make individual views subscribe separately to the entire backend event stream.

## 4.4 Basic project access

Implement a minimal project selector using the native macOS file picker.

A selected directory becomes the working directory for subsequent OpenCode operations.

For now, support one active project.

Retain the project identifier and directory as distinct values. This will matter when multiple projects and worktrees are introduced.

### Phase 1 acceptance tests

- Connect to an already-running service.
- Start a service when appropriate.
- Reject an incompatible version clearly.
- Recover after a temporary backend interruption.
- Confirm that the official TUI and Swift client can connect to the same service.
- Confirm that closing the Swift client does not terminate unrelated OpenCode activity.

**Milestone:** A native macOS application can reliably connect to OpenCode.

---

# 5. Phase 2 — Single-Session, Single-Agent Client

**Objective:** Deliver the first genuinely useful version.

This phase provides normal primary-agent operation using Build and Plan.

There is one active project and one visible session at any given time.

## 5.1 Session lifecycle

Implement the ability to:

- Create a session.
- Load an existing session.
- Retrieve its message history.
- Send a prompt.
- Follow its execution.
- Interrupt execution.
- Resume interaction.
- Rename a session.

Session history should come from OpenCode, not a separately maintained local conversation database.

The Swift client should persist only the local information needed for presentation and restoration.

Although the UI supports one active session, design the state storage around session identifiers. Do not embed one global transcript directly inside the application root.

## 5.2 Primary-agent selection

Begin with the two built-in primary agents:

**Build**
- Normal implementation agent.
- Uses the backend's configured permissions and tools.

**Plan**
- Planning-oriented agent.
- Uses the backend's restrictions on editing project files.

The frontend must not attempt to enforce either agent's operational restrictions itself.

Agent selection must use OpenCode's existing agent operations.

Retrieve the available agent definitions rather than treating Build and Plan as permanently hardcoded application concepts.

The first interface may display only these two options. Internally, the implementation should already support selecting an agent by its identifier.

Also maintain model selection separately from agent selection.

Switching from Build to Plan must not accidentally discard the session's selected model.

## 5.3 Prompt submission

Implement a basic multiline text composer.

Required behaviour:

- Edit a prompt.
- Submit it to the active session.
- Display it in the transcript.
- Observe the backend processing it.
- Receive the resulting output.
- Interrupt the current execution.

For the initial version, disable submission while an incompatible operation is pending.

Prompt steering, deferred queues, file attachments and advanced composer controls can follow later.

Do not simulate a successful submission before the backend accepts it.

## 5.4 Transcript implementation

This is the most important internal component of Phase 2.

Do not represent an assistant response as one continuously appended string.

Represent it as an ordered collection of structured message parts.

Support at least:

- User messages.
- Assistant text.
- Incremental response updates.
- Reasoning parts, where provided.
- Tool calls.
- Tool results.
- Tool errors.
- Execution state.
- Final completion or interruption.

Initially, tool output may use a generic expandable renderer.

Specialized tool presentation is unnecessary at this stage.

The transcript must correctly merge incoming updates without duplicating earlier content.

Use backend identifiers and the documented event semantics when updating messages and parts.

## 5.5 Permissions

Permission handling belongs in the first functional client.

Otherwise, an agent can become blocked while the frontend appears to be waiting indefinitely.

Implement:

- Detection of pending permission requests.
- Display of the requested action and resource.
- Available approval or rejection responses.
- Submission of the selected response.
- Recovery of unresolved requests after reconnecting.

Use OpenCode's actual permission-response choices.

Do not enable permanent automatic approval as a workaround for missing UI functionality.

## 5.6 Session state

The user must be able to distinguish between:

- Idle.
- Working.
- Waiting for permission or user input.
- Interrupted.
- Failed.
- Completed.

These states should be derived from OpenCode, not inferred merely from whether text is currently arriving.

## 5.7 Minimal interface

A temporary interface is sufficient:

- Project name.
- Session title.
- Agent selector.
- Model selector.
- Scrollable transcript.
- Prompt composer.
- Stop button.
- Permission prompt.

The visual arrangement is intentionally unspecified.

### Phase 2 acceptance tests

1. Open a repository.
2. Create a session using Build.
3. Request a small code change.
4. Observe tool calls and results.
5. Respond to a permission request.
6. Receive the final response.
7. Switch to Plan and submit a planning request.
8. Interrupt an active execution.
9. Quit and reopen the application.
10. Recover the original session and its history.

Also verify that the official TUI correctly displays the work performed through SwiftUI, and vice versa.

**Milestone:** The application can replace the TUI for basic single-agent work.

Do not start implementing subagent presentation until this milestone works reliably.

---

# 6. Phase 3 — Subagent Support

**Objective:** Extend the existing client to support delegated agent execution.

This is the first major architectural expansion.

Do not implement an independent orchestration engine.

OpenCode remains responsible for invoking subagents, scheduling their execution, applying permissions and maintaining child sessions.

The client makes those operations observable and accessible.

## 6.1 Agent discovery

Extend the existing agent selector to understand OpenCode's agent modes:

- Primary.
- Subagent.
- Both.

Support custom project-level and global agent definitions.

Do not maintain a duplicate agent registry in Swift.

## 6.2 Session relationships

Represent parent/child relationships explicitly.

The expected logical structure is:

- Parent session.
  - Child session A.
  - Child session B.
  - Child session C.

Child sessions must retain independent state, messages, status and identity.

A parent transcript may reference a child execution, but it must not own that child's entire transcript.

Use the backend's actual session relationship data to build this structure.

## 6.3 Subagent navigation

Initially, a simple selectable child-session list is sufficient.

Required operations:

- Discover child sessions.
- Open an individual child's transcript.
- Return to its parent.
- Inspect completed children.
- Observe background child activity.
- Distinguish concurrent child executions.

Navigation should not imply a change of execution state.

Opening or closing a child transcript must not automatically interrupt it.

## 6.4 Concurrent state updates

Expand event routing so updates can reach multiple session stores.

A useful separation is:

**Event stream → Event dispatcher → Session-specific state**

The active view observes only the session it presents.

Other session stores continue receiving relevant updates.

This is necessary preparation for tabbed sessions.

Do not rebuild the application's event architecture around the currently selected child.

## 6.5 Delegated tool calls

Subagent invocations should be represented as structured execution events.

The parent should expose:

- Target agent.
- Execution status.
- Child-session relationship.
- Available result.
- Errors, if any.

Do not require every child transcript to be fully expanded inside its parent's transcript.

That presentation decision can be made later.

## 6.6 Permission routing

A permission request must identify the correct session.

The client must support handling a request from a child even when its parent is currently visible.

Do not merge all permissions into an anonymous global approval dialog.

### Phase 3 acceptance tests

- Build invokes a configured subagent.
- The resulting child session is discovered.
- Its transcript remains independently accessible.
- Several children can execute concurrently.
- Child events do not corrupt the parent's messages.
- Permission requests identify the correct session.
- Returning from a child does not interrupt it.
- Restarting the client restores the session hierarchy.

**Milestone:** OpenCode's multi-agent functionality works through the native client.

---

# 7. Phase 4 — Multiple Sessions and Tabs

**Objective:** Support independent concurrent sessions without duplicating application state.

At this point, the architecture should already support several live sessions because Phase 3 required it.

Tabs now become a presentation and navigation feature, rather than another execution-management system.

## 7.1 Session management

Introduce:

- Session creation.
- Session listing.
- Session selection.
- Session restoration.
- Session renaming.
- Explicit session deletion.
- Persistent active-session information.

Keep session identity separate from tab identity.

A session may exist without an open tab.

## 7.2 Tab management

Implement a local tab coordinator.

Its responsibilities are limited to:

- Opening a session view.
- Closing a session view.
- Focusing a session.
- Reordering open views.
- Restoring the previous selection.
- Displaying session activity indicators.

Closing a tab must not delete the corresponding OpenCode session.

It must not interrupt an active agent unless the user explicitly requests that operation.

## 7.3 Background execution

Session updates must continue independently of tab selection.

For example:

1. Session A begins working.
2. The user opens Session B.
3. Session A invokes several subagents.
4. Session B begins a separate task.
5. The user returns to Session A.

The application must retain the correct state of both sessions without requiring either transcript to remain mounted as a SwiftUI view.

## 7.4 Project separation

Extend the application to support sessions belonging to different projects.

Project directory and session ID must be included when routing operations that require project or location context.

Do not use one mutable global working directory as an implicit argument for every session.

## 7.5 Attention management

Introduce an application-level attention coordinator.

Initially, it only needs to track:

- Completed executions.
- Failed executions.
- Pending permissions.
- Pending user questions.

Native macOS notifications can be added without modifying session execution code.

### Phase 4 acceptance tests

- Several sessions execute concurrently.
- Switching tabs causes no loss of updates.
- Closing a tab does not stop execution.
- Reopening a tab restores current state.
- Child sessions retain their correct parent.
- Permission requests from inactive sessions remain accessible.
- Sessions from separate projects do not exchange data.
- Restarting the application restores previously open session views.

**Milestone:** A functional multi-session OpenCode client.

---

# 8. Phase 5 — Gradual TUI Feature Parity

**Objective:** Expand functionality after the fundamental architecture has been proven.

Do not treat this as one large implementation task.

Divide it into independent feature slices.

## 5A. Composer improvements

Implement:

- Prompt steering.
- Deferred prompt queue.
- File and directory references.
- Image attachments.
- File autocomplete.
- Line-range references.
- Prompt history.
- Draft preservation.
- Slash commands.

Keep these features inside a dedicated composer implementation, not the session coordinator.

## 5B. Conversation improvements

Implement:

- Specialized tool-result renderers.
- Better Markdown handling.
- Reasoning visibility controls.
- Execution timing and usage information.
- Session compaction.
- Conversation undo/redo.
- Session forks.
- Export functionality supported by the backend.

## 5C. Development tools

Introduce:

- Git status.
- Diff inspection.
- Changed-file navigation.
- Unified and split diff presentation.
- Reviewed-file tracking.
- Worktree selection and management.
- Running command inspection.

Use backend operations where available.

Avoid introducing a second, independent source of truth for repository changes.

## 5D. Configuration and integrations

Implement interfaces for:

- Available providers.
- Available models and variants.
- Primary agents.
- MCP integrations.
- Project configuration.
- Relevant plugin status.
- Keybindings and application preferences.

Prefer reading existing configuration through the backend rather than parsing and rewriting OpenCode configuration files independently.

## 5E. Native macOS functionality

Begin refining platform-specific behaviour:

- Native application menu.
- Keyboard shortcuts.
- Window restoration.
- Notifications.
- Copy and paste.
- Drag and drop.
- File selection.
- Optional multiple windows.
- Appearance preferences.

Each addition should remain independent of the fundamental execution model.

**Milestone:** Core functional parity with the official TUI, excluding terminal-specific extensions that require separate compatibility work.

---

# 9. Phase 6 — TUI Plugin Compatibility Investigation

**Objective:** Determine whether existing OpenCode TUI plugins can operate inside the Swift client without requiring plugin authors to rewrite them.

This is an investigation and experimental implementation phase.

Do not promise full compatibility before testing it.

## 9.1 Understand the existing plugin boundary

OpenCode V2 provides two relevant plugin categories.

**Server plugins** extend OpenCode functionality through backend integrations, tools, hooks, and potentially custom RPC operations.

These should continue operating because the Swift client connects to the same OpenCode service.

**TUI plugins** extend the terminal frontend itself.

They may register commands, routes, keyboard handlers, notification behaviour, JSX components, rendering slots and custom presentation logic.

These are not automatically compatible with SwiftUI.

Existing OpenTUI/Solid components cannot simply be interpreted as native SwiftUI views.

## 9.2 Compatibility approaches

Evaluate the following independently.

### Approach A — Native server-plugin support

Allow the Swift client to access relevant server-plugin functionality.

Support generic plugin RPC methods and events where the plugin exposes them.

This is the most straightforward form of plugin interoperability.

It does not reproduce custom terminal views.

**Estimated difficulty: Low–Medium.**

### Approach B — JavaScript plugin host with a Swift bridge

Investigate running compatible TUI plugin JavaScript in an embedded or companion runtime.

Implement an adapter that maps selected TUI APIs to native application operations.

Potential compatibility targets:

- Command registration.
- Simple notification calls.
- Session navigation.
- Tab operations.
- Plugin storage.
- Basic input and selection dialogs.

This approach would allow some unmodified plugin packages to run, provided the adapter implements their required API surface.

However, arbitrary JSX rendering remains unresolved.

**Estimated difficulty: High.**

### Approach C — Embed the actual terminal renderer

Investigate hosting OpenCode's existing OpenTUI environment inside a dedicated terminal surface.

This could preserve more existing plugin behaviour because plugins would still use their expected rendering environment.

However, it would effectively introduce a terminal frontend inside the native application.

It would not provide automatic native SwiftUI integration.

**Estimated difficulty: Medium–High for a prototype; potentially higher for polished integration.**

### Approach D — Full native compatibility layer

Investigate the feasibility of translating the complete TUI plugin API, including arbitrary OpenTUI/Solid components, into SwiftUI.

This would require substantial compatibility infrastructure.

A generic translation is not guaranteed to be practical.

**Estimated difficulty: Very High.**

## 9.3 Plugin test suite

Create a small set of representative plugins:

1. A plugin that registers a command.
2. A plugin that displays a toast.
3. A plugin that adds content to an existing TUI slot.
4. A plugin that renders a custom JSX dialog or panel.
5. A plugin that communicates with a server-side RPC extension.

Attempt to run each plugin unchanged.

Document what works, what fails, and which compatibility layer is required.

## 9.4 Decision gate

At the end of this investigation, choose between:

- Limited native plugin compatibility.
- A broader JavaScript bridge.
- Embedded terminal rendering for unsupported plugins.
- A documented native plugin API requiring adaptation.

Do not allow this experimental work to destabilize normal session functionality.

**Milestone:** A proven plugin compatibility strategy, with the extent of unmodified-plugin support established through tests.

---

# 10. Phase 7 — Stability and Distribution

Once the client is functionally mature, prepare it for regular use.

Address:

- Service-version compatibility.
- Reconnection and state recovery.
- Error reporting and diagnostics.
- Authentication-token handling.
- Process lifecycle.
- Performance with large transcripts.
- Memory use during concurrent sessions.
- macOS app permissions and sandbox requirements.
- Installation and update procedures.

The application must remain compatible with ordinary OpenCode usage outside the Swift client.

A user should be able to alternate between the TUI and native client without migrating projects, duplicating configuration or maintaining separate sessions.

---

# 11. Development and Validation Rules

These rules apply throughout implementation.

## 11.1 One functional slice at a time

Complete and test each milestone before beginning the next.

Do not implement incomplete versions of five future features while the current phase remains unreliable.

## 11.2 Keep backend behaviour authoritative

Do not implement fake Plan-mode restrictions, local orchestration, independent message persistence, or alternate permission rules.

Use OpenCode's actual functionality.

## 11.3 Avoid premature UI commitments

Temporary controls are acceptable.

Application architecture must not depend on the visual structure of those controls.

## 11.4 Test with the actual backend

Use mocked responses for focused unit testing, but require live integration tests against a pinned OpenCode V2 release before completing a milestone.

Use the official TUI as a reference client when verifying state synchronization.

## 11.5 Maintain architectural boundaries

Before extending an existing file, establish whether the change belongs to that file's current responsibility.

Extract new responsibilities instead of continuously extending a central manager.

Avoid duplicated session state, duplicated event processing and unrelated view-specific networking.

## 11.6 Preserve operational correctness

A feature is incomplete if it:

- Works only while one specific view is open.
- Loses data after reconnection.
- Silently ignores backend errors.
- Requires restarting OpenCode unnecessarily.
- Breaks existing TUI interaction.
- Only works with hardcoded model, agent or session identifiers.

## 11.7 Maintain a short project worklog

At each milestone, record:

- Implemented functionality.
- Tested behaviour.
- Known limitations.
- Architecture decisions.
- Relevant API changes.
- Deferred work.

This should make it possible to continue development without rediscovering previous decisions.

---

# 12. Implementation Order Summary

| Stage | Deliverable |
|---|---|
| Phase 0 | Project foundation and verified API contract |
| Phase 1 | Working backend connection and event transport |
| Phase 2 | Usable Build/Plan single-agent client |
| Phase 3 | Child sessions and concurrent subagents |
| Phase 4 | Independent sessions, tabs and project navigation |
| Phase 5 | Expanded TUI feature parity |
| Phase 6 | TUI plugin compatibility experiments |
| Phase 7 | Stability, integration and distribution |

Every phase must leave the previous functionality operational.

**The principal technical priority is a reliable session and event synchronization system.** Once this exists, adding new views, rearranging the interface, or introducing additional session-navigation methods should not require major changes to the OpenCode integration.

---

# 13. Immediate First Implementation Task

Begin with Phase 0 and the smallest part of Phase 1.

The initial development assignment is:

1. Create the Xcode project.
2. Establish the minimum supported macOS target.
3. Inspect the current V2 client API and service-discovery contract.
4. Implement a native service connection.
5. Retrieve backend information through a real HTTP request.
6. Connect to the live event stream.
7. Display the connection state in a temporary SwiftUI window.
8. Test against an existing OpenCode installation.

Do not implement the composer, transcript, tabs, subagents, custom styling or plugins during this task.

The first checkpoint is complete when the native application can connect to the same OpenCode backend used by the official TUI and maintain that connection reliably.

Only then begin Phase 2.
