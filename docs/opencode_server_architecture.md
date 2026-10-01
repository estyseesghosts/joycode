# OpenCode v2 Client–Server Architecture

## Abstract

OpenCode is fundamentally a **client–server application**.

The server owns the actual coding-agent runtime. It owns sessions, model execution, tools, permissions, workspace state, configuration, provider connections, MCP servers, language servers, file access, version-control integration, terminal processes, and persistence.

The TUI, desktop application, web application, SDK consumers, and IDE integrations are clients of this backend.

This is not only an architectural abstraction. OpenCode exposes the backend as an HTTP API, publishes an OpenAPI schema, generates SDK clients from that API, and uses those client interfaces inside its own official frontends. The official server documentation explicitly describes the TUI as a client of the OpenCode server.

The important complication in September 2026 is that OpenCode v2 is still migrating between two API generations:

| Name used in this report | API style | Main client library |
|---|---|---|
| Legacy API | `/session`, `/global/event`, `/provider`, etc. | `@opencode-ai/sdk/v2` |
| Current v2 API | `/api/session`, `/api/event`, `/api/provider`, etc. | `@opencode-ai/client` |
| Compatibility layer | Chooses/translates between both | OpenCode app internals |

The naming is confusing because `@opencode-ai/sdk/v2` currently refers to the older unprefixed API. OpenCode's own migration document explicitly warns about this. The desktop/web app is currently a hybrid client.

Therefore, there is not yet one completely isolated "v2 client architecture." There is a new architecture being introduced while existing clients continue to support the older server interface.

---

# 1. Fundamental Architecture

The simplest model is:

```text
┌─────────────────────────────────────────────────────────────┐
│                         CLIENTS                             │
│                                                             │
│   Terminal TUI       Desktop       Web       IDE/SDK        │
│        │                 │           │           │           │
└────────┼─────────────────┼───────────┼───────────┼───────────┘
         │                 │           │           │
         │ SDK / HTTP / SSE / WebSocket            │
         │                 │           │           │
┌────────▼─────────────────▼───────────▼───────────▼───────────┐
│                     OPENCODE SERVER                         │
│                                                             │
│  HTTP API                                                   │
│  Event streams                                              │
│  Session runtime                                            │
│  Agent loop                                                 │
│  Model/provider layer                                       │
│  Tool execution                                             │
│  Permissions/questions                                      │
│  MCP / LSP / formatters                                     │
│  Filesystem / VCS                                           │
│  PTYs / terminal processes                                  │
│  Configuration                                              │
│  Persistence                                                │
└─────────────────────────────────────────────────────────────┘
```

The frontend does not contain the coding agent itself.

It tells the server things such as:

```text
create a session
send this prompt
use this agent
use this model
approve this permission
answer this question
abort this session
give me these messages
give me this file
open a terminal
```

The server performs those operations and sends state changes back to the frontend.

The server publishes an OpenAPI 3.1 interface and exposes its schema through `/doc`. The older generated SDK and the newer `@opencode-ai/client` are both derived from server contracts rather than being independent implementations of OpenCode behavior.

---

# 2. What Runs Where

## 2.1 Server responsibilities

The server is authoritative for:

| Area | Server responsibility |
|---|---|
| Sessions | Create, persist, update, fork, archive/delete, compact |
| Messages | Store user and assistant messages |
| Parts | Store text, reasoning, tools, files, patches, etc. |
| Models | Resolve provider/model and make inference calls |
| Agents | Resolve agent configuration and rules |
| Tools | Register and execute tools |
| Subagents | Start and supervise subagent work |
| Permissions | Evaluate rules and pause execution when approval is needed |
| Questions | Pause work and request structured input |
| Files | Read, search, inspect, and modify workspace files |
| Shell | Execute commands |
| PTY | Own interactive terminal processes |
| VCS | Read branch/status/diffs and apply supported operations |
| MCP | Start and communicate with MCP servers |
| LSP | Manage language-server integration |
| Formatters | Discover and execute configured formatting |
| Config | Resolve global/project configuration |
| Authentication | Provider credentials and OAuth |
| Persistence | Store durable project/session/message state |
| Events | Publish runtime changes to clients |

A client should not independently reimplement those systems.

The server is the source of truth.

---

## 2.2 Client responsibilities

The client primarily owns:

| Area | Client responsibility |
|---|---|
| Presentation | Render messages, tools, status, dialogs |
| Navigation | Projects, sessions, tabs, history |
| Input | Prompt editor, attachments, commands |
| Selection | Agent, model, variant |
| Synchronization | Bootstrap state and consume events |
| Permission UI | Ask the user and submit the answer |
| Question UI | Present questions and submit answers |
| Terminal UI | Display a server-owned PTY |
| Error UI | Display server/transport/session failures |
| Preferences | Client-only UI preferences |
| Connection | Start/connect/reconnect to a server |

This split is the main reason several different OpenCode frontends can exist.

---

# 3. The Server Core

The current server implementation lives around:

```text
packages/opencode/src/server/
```

The main entry point is:

```text
packages/opencode/src/server/server.ts
```

Its central public abstraction is `Server.Default()`.

Conceptually:

```text
Server.Default()
    │
    ├── app.fetch(Request)
    └── app.request(...)
```

`Server.Default()` builds the HTTP router as an in-memory application. A real listening socket is not required.

The implementation obtains the handler from:

```text
HttpApiApp.webHandler().handler
```

and exposes it through a normal Fetch-style interface.

This distinction is important:

```text
HTTP semantics
       ≠
TCP socket requirement
```

A client can use the same API:

```text
Request
   ↓
HttpApi router
   ↓
OpenCode services
```

without sending anything through the operating-system networking stack.

When a real remote-accessible server is required, `Server.listen()` wraps the same server architecture in a Node HTTP listener.

---

# 4. `Server.Default()` Versus `Server.listen()`

These represent two transport modes.

## `Server.Default()`

This is the embedded form.

```text
client
  │
  │ custom fetch()
  ▼
Server.Default().app.fetch()
  │
  ▼
HTTP router
```

There is no TCP connection.

The request still behaves like HTTP internally. The generated client does not need to know that the request did not travel over a network.

This is useful for:

- local CLI operation;
- embedded SDK operation;
- tests;
- private TUI/server integration.

The current interactive CLI has code paths that create a generated client with:

```text
baseUrl = http://opencode.internal
```

and provide a custom `fetch` implementation that forwards requests directly into `Server.Default().app.fetch(...)`.

## `Server.listen()`

This creates a real listener:

```text
client
   │
 HTTP
   ▼
127.0.0.1:<port>
   │
   ▼
Server.listen()
   │
   ▼
same server services
```

It is used when:

- running `opencode serve`;
- accessing OpenCode remotely;
- the desktop app starts its sidecar;
- an external client attaches;
- the TUI is explicitly exposed on a network port.

The standard server defaults remain:

```text
hostname: 127.0.0.1
port:     4096
mDNS:     disabled
```

A password can protect the server with HTTP Basic authentication. The default username is `opencode`.

---

# 5. Current TUI Architecture

The TUI is not the OpenCode backend.

It is now being isolated into:

```text
@opencode-ai/tui
```

The project explicitly defines the SDK as the boundary between the TUI package and OpenCode backend services. Backend operations required by the TUI are supposed to be exposed through the server/API rather than imported directly from backend implementation code.

The target dependency direction is:

```text
packages/opencode ──┐
                    ├──> @opencode-ai/tui ──> OpenCode SDK/API
packages/cli ───────┘
```

This makes the terminal renderer a true frontend rather than part of the agent runtime.

---

# 6. TUI Local Transport

The existing legacy TUI host retains an embedded worker/server adapter.

The topology is approximately:

```text
Main CLI process
│
├── OpenTUI renderer
│
├── @opencode-ai/tui
│
└── Worker
     │
     ├── OpenCode backend
     ├── Server.Default()
     └── global event bus
```

The CLI creates two bridges.

## Request bridge

`createWorkerFetch()` converts a normal Fetch request into RPC data:

```text
Request
  ↓
{
    url,
    method,
    headers,
    body
}
  ↓
worker RPC
  ↓
Server.Default().app.fetch()
  ↓
{
    status,
    headers,
    body
}
  ↓
Response
```

From the TUI SDK's point of view, this still looks like HTTP.

The logical URL can therefore remain something like:

```text
http://opencode.internal
```

even though no server exists at that network address.

## Event bridge

The worker also subscribes to OpenCode's global event bus.

Conceptually:

```text
GlobalBus
   ↓
worker
   ↓ RPC "global.event"
main process
   ↓
TUI event source
```

This avoids opening a separate SSE network connection for the local embedded case.

When network flags are explicitly used, the TUI host can instead start a real `Server.listen()` listener and use normal HTTP/SSE transport.

This means the TUI has a transport abstraction:

```text
                 ┌── embedded fetch + RPC events
TUI → SDK →──────┤
                 └── HTTP + SSE
```

The UI code can largely remain identical.

---

# 7. TUI SDK Context

Inside the shared TUI, the SDK context creates an OpenCode client.

Conceptually:

```text
createOpencodeClient({
    baseUrl,
    directory,
    fetch,
    headers
})
```

The TUI does not call backend service classes directly.

It calls generated methods such as:

```text
sdk.client.session.list(...)
sdk.client.session.get(...)
sdk.client.session.messages(...)
sdk.client.session.prompt(...)
sdk.client.permission.reply(...)
sdk.client.provider.list(...)
sdk.client.lsp.status(...)
```

The shared TUI package's architecture explicitly requires API/SDK operations to be the boundary for backend data.

---

# 8. TUI Event Connection

When there is no host-provided event source, the TUI connects to the server event stream.

The TUI maintains its own event queue.

The current implementation uses roughly one rendering-frame interval for event batching. Multiple server events can therefore result in one Solid state update rather than one complete redraw per token.

The logical structure is:

```text
SSE / host event source
        ↓
   handleEvent()
        ↓
      queue
        ↓
~16 ms batching
        ↓
 Solid batch()
        ↓
 state reducers
        ↓
   terminal render
```

This matters because model responses may generate very frequent text and tool state updates.

The event connection also reconnects after failures rather than treating a dropped SSE stream as the end of the session.

---

# 9. TUI State Synchronization

One of the most important client components is:

```text
packages/tui/src/context/sync.tsx
```

It is effectively the TUI's local read model.

The store includes state for:

| State | Purpose |
|---|---|
| `provider` | Configured provider information |
| `provider_default` | Default model mappings |
| `provider_next` | Provider inventory and connected state |
| `provider_auth` | Authentication methods |
| `agent` | Available agents |
| `command` | Available slash/custom commands |
| `config` | Resolved config |
| `session` | Session metadata |
| `session_status` | Running/idle states |
| `session_diff` | Session-generated changes |
| `todo` | Session todos |
| `message` | Message metadata by session |
| `part` | Message parts |
| `permission` | Pending permission requests |
| `question` | Pending questions |
| `lsp` | Language-server status |
| `mcp` | MCP server state |
| `mcp_resource` | MCP resources |
| `formatter` | Formatter status |
| `vcs` | Repository state |
| `console_state` | Console/provider account information |

This is direct evidence that a real OpenCode client is much more than a text chat renderer.

---

# 10. TUI Bootstrap

The TUI uses staged bootstrap.

The important initial requests include:

```text
config.providers()
provider.list()
app.agents()
config.get()
project sync
session.list()
```

It then loads additional information such as:

```text
command.list()
lsp.status()
mcp.status()
MCP resources
formatter.status()
session.status()
provider.auth()
vcs.get()
workspace state
```

The state progresses through:

```text
loading
   ↓
partial
   ↓
complete
```

This permits the interface to become useful before every optional subsystem has finished loading.

---

# 11. Per-Session Hydration

Opening a session requires more than retrieving a `Session` object.

The TUI concurrently retrieves approximately:

```text
session.get(sessionID)
session.messages(sessionID)
session.todo(sessionID)
session.diff(sessionID)
```

The message response includes both message metadata and parts.

The TUI then constructs:

```text
Session
 ├── Message
 │    ├── Part
 │    ├── Part
 │    └── Part
 ├── Message
 │    └── ...
 ├── Todo[]
 └── Diff[]
```

A subtle synchronization problem exists here.

Suppose the client begins:

```text
GET messages
```

and while that request is in flight, SSE delivers:

```text
message.part.updated
```

If the GET response is older than the SSE event and the client simply replaces its local state, it loses newer data.

The TUI therefore tracks message and part IDs that changed while hydration was running. It preserves those live versions when merging fetched state.

That is a significant part of what makes an OpenCode frontend correct.

---

# 12. Desktop Application Architecture

The desktop application uses Electron.

Its architecture is approximately:

```text
┌──────────────────────────────────────────┐
│ Electron main process                    │
│                                          │
│   starts/manages local OpenCode server   │
│                │                         │
└────────────────┼─────────────────────────┘
                 │
           loopback HTTP
                 │
┌────────────────▼─────────────────────────┐
│ Electron renderer                        │
│                                          │
│ @opencode-ai/app                         │
│ OpenCode SDK/client                      │
│ SolidJS UI                               │
└──────────────────────────────────────────┘
```

The Electron main process is not itself the coding agent.

It primarily owns desktop integration and the lifecycle of a local OpenCode sidecar.

---

# 13. Desktop Sidecar Startup

The current desktop main process allocates a local loopback server.

For the existing default sidecar path it:

```text
1. chooses an unused loopback port
2. generates a random password
3. starts the OpenCode sidecar
4. exposes:
       URL
       username
       password
   to the renderer
5. waits for health
```

The username is normally:

```text
opencode
```

The password is generated for that local process.

The renderer therefore connects to something conceptually like:

```text
http://127.0.0.1:58317
Authorization: Basic ...
```

rather than importing agent/runtime code into the renderer process.

The sidecar itself calls `Server.listen()` and permits the Electron renderer origin through CORS.

---

# 14. Desktop Server Lifetime

The sidecar generally persists for the desktop application lifetime.

Creating a new conversation does **not** create an entirely new OpenCode backend process.

Instead:

```text
Desktop launch
     ↓
server starts
     ↓
project A session 1
project A session 2
project B session 3
...
     ↓
Desktop exits
     ↓
server stops
```

This differs from older TUI process lifetimes, where the embedded worker is tied more closely to the CLI process.

---

# 15. Web Application Architecture

The web interface uses substantially the same application-side client architecture as the desktop renderer.

The main difference is server ownership.

```text
Desktop:
Electron main
    ↓ starts
OpenCode server
    ↓
renderer client
```

```text
Web:
already-running OpenCode server
    ↓ HTTP/SSE
browser application
```

Consequently, the browser and desktop renderer share much of:

```text
packages/app/
```

including connection management, session projection, event reduction, protocol compatibility, and server-scoped state.

---

# 16. Protocol Detection in the Current App

Because the frontend currently supports both API generations, it needs to determine which server it is connected to.

The compatibility logic probes health endpoints.

Conceptually:

```text
GET /global/health
      │
      ├── healthy legacy response
      │       → legacy protocol
      │
      └── otherwise
              ↓
         GET /api/health
              │
              └── current protocol
```

This protocol distinction is then used when building API and event adapters.

The migration is explicit in OpenCode's source: the app is described as **currently hybrid**.

---

# 17. Two Client Implementations Inside the Current App

The hybrid frontend currently works with two client interfaces.

## Legacy generated SDK

The older interface is represented by:

```text
@opencode-ai/sdk/v2
```

Despite the name, its important production routes are the old unprefixed routes.

Examples:

```text
/session
/provider
/config
/global/event
```

## New Promise client

The newer architecture uses:

```text
@opencode-ai/client/promise
```

with operations mounted primarily under:

```text
/api/...
```

The application builds a compatibility wrapper around these two interfaces so UI code does not need two completely independent implementations.

`server-compat.ts`, for example, translates operations including prompt, command, shell, compact, remove, rename, and permission replies between the different API representations.

---

# 18. The SDK Is a Generated Protocol Layer

The SDK is intentionally thin.

The older public SDK exposes methods such as:

```text
client.session.create(...)
client.session.list(...)
client.session.prompt(...)
client.file.read(...)
client.event.subscribe(...)
```

The types are generated from the server's OpenAPI schema.

The newer v2 client follows the same general principle:

```text
const client = OpenCode.make({
    baseUrl: "http://localhost:4096"
})

await client.session.create(...)
await client.session.prompt(...)
```

The newer `@opencode/client` API is generated from the same contract as the HTTP API.

Therefore:

```text
UI
 ↓
generated client
 ↓
HTTP contract
 ↓
server handler
 ↓
service
```

is the intended boundary.

---

# 19. Location and Runtime Context

OpenCode operations must know **which project/workspace directory they operate on**.

This becomes particularly important when one server serves multiple projects.

The older SDK commonly carries a directory with the client:

```text
createOpencodeClient({
    baseUrl,
    directory
})
```

Internally this can become a directory header or query parameter.

The newer v2 model makes context more explicit.

There are three important scopes:

| Scope | Meaning |
|---|---|
| Server scope | Independent of active directory |
| Request/runtime scope | Uses directory and optionally workspace |
| Session scope | Uses context pinned into the session |

The v2 API design treats session operations specially.

A session is created under a location:

```text
directory
workspaceID?
```

After creation, operations like:

```text
session.prompt
session.get
session.diff
```

can resolve the location from the session itself.

Conceptually:

```text
POST /api/session
location = /repo/foo
        ↓
session ses_123
pinned location = /repo/foo
```

Later:

```text
POST /api/session/ses_123/prompt
```

does not need the caller to rediscover where `ses_123` lives.

This avoids a class of errors where a session ID and ambient current directory disagree.

---

# 20. Session as the Core Unit

A `Session` is not merely a UI tab.

It is the server-side execution and conversation container.

A session can hold or reference:

```text
ID
project
directory
workspace
title
parent
timestamps
agent/model state
permission rules
share state
revert state
summary
message history
todos
diffs
background jobs
```

Session persistence and manipulation are implemented in the server rather than in the client.

The session service contains operations including:

```text
create
get
list
children
remove
fork
touch
setTitle
setArchived
setMetadata
setAgentModel
setPermission
setRevert
clearRevert
setSummary
setShare
setWorkspace
messages
removeMessage
removePart
updatePart
updatePartDelta
```

The frontend calls API representations of these operations rather than touching storage directly.

---

# 21. Messages and Parts

OpenCode does not model a conversation as:

```text
message = one string
```

A message contains structured **parts**.

Conceptually:

```text
Message
├── TextPart
├── ReasoningPart
├── ToolPart
├── FilePart
├── AgentPart
├── StepStartPart
├── StepFinishPart
├── PatchPart
├── SnapshotPart
├── RetryPart
└── CompactionPart
```

Exact schemas are evolving during v2, but this structured-part concept is fundamental.

For example, one assistant response can logically become:

```text
AssistantMessage
│
├── reasoning
│
├── text
│
├── tool call: read
│    ├── input
│    ├── status
│    └── output
│
├── text
│
├── tool call: edit
│    └── ...
│
└── step finish
```

A complete client therefore cannot safely treat every server response as Markdown text.

It must understand the discriminated part types it chooses to support.

---

# 22. Tool State

A tool call progresses through states.

The server processor contains explicit functions for tool-state transitions, including:

```text
settleToolCall
readToolCall
updateToolCall
completeToolCall
failToolCall
ensureToolCall
```

The processor receives model stream events and turns them into persistent message parts and OpenCode events.

A frontend can therefore render:

```text
pending
   ↓
running
   ↓
completed
```

or:

```text
pending
   ↓
running
   ↓
error
```

without running the tool itself.

---

# 23. Prompt Execution Pipeline

Sending a user prompt triggers a much larger server-side pipeline.

The high-level flow is:

```text
Client
  │
  │ session.prompt()
  ▼
HTTP session route
  │
  ▼
SessionPrompt
  │
  ├── validate session
  ├── resolve agent
  ├── resolve model
  ├── resolve input parts
  ├── resolve files/attachments
  ├── create user message
  ├── construct instructions/system prompt
  ├── resolve available tools
  └── enter agent loop
        │
        ▼
       LLM
        │
   streaming output
        │
        ▼
Session
