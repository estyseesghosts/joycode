# CPU investigation — offline baseline, connected reproduction still open

> The sections below record the initial offline pass. The user subsequently authorized connected profiling and additional tests on the same date; see the follow-up section at the end. Initial authorization limits/results are retained as history, not the final scope.

Date: 2026-10-05. **No excessive CPU reproduced offline; original cause unresolved. R11 remains on hold.** No application fix is justified by these measurements. This is neither a Debug-overhead diagnosis nor Phase 1 acceptance.

## Report and process identity

User clarification: “not exactly sure, believe connected idle.” Original CPU percentage, PID, product configuration, launch mode, selected session/history size and event traffic remain unknown.

Initial process inspection found no Joycode, XCTest runner, debugserver, xcodebuild or swift-frontend process. The highest entry in that snapshot was an OpenCode executable, PID 32551, at 52.2% in `ps`; that is **not Joycode** and is not evidence about the user's earlier complaint. No unrelated process was sampled, stopped or modified.

Measured products were the existing R10 artifacts under:

`/private/var/folders/dg/dztwhk5n6rb9xr8jt3t0nkf00000gp/T/opencode/joycode-hardening-derived/Build/Products/`

- Debug: arm64 executable plus `Joycode.debug.dylib`; sampled executable UUID `AFCD7961-8870-3E5F-9876-23F32B859D8A`, dylib UUID `F96B6890-7D81-3B31-A7AA-7147F8EAF5FB`.
- Release: distinct universal arm64/x86_64 executable, running ARM64; sampled ARM64 UUID `509F2342-B7CC-3C2A-8BD4-2DBBA0020BAC`.
- Both products last modified at 18:40 on October 5. R10 records their successful separate builds. Current project settings specify Debug `-Onone`, `DEBUG`, testability; Release `-O`, `RELEASE`, no testability. No new build or test was run for this documentation-only investigation.
- Environment: macOS 27.0.1 (26A434), Xcode 26.6 (17F113).

## Safety and source inspection

A fresh read-only leaf delegate inspected launch/fixture/observation paths; primary independently read `JoycodeApp`, `DiagnosticComposition`, `ServiceConnectionOwner`, `OfflineUITestComposition` and the actual sampled call graphs.

Production construction does not auto-connect (`App/JoycodeApp.swift:47–77`); registration discovery is deferred inside the connection closure (`App/Composition/DiagnosticComposition.swift:7–20`). The owner starts disconnected and discovery requires `connect()` (`State/Connection/ServiceConnectionOwner.swift:26–49`). No Connect or other action controls were used. Ordinary disconnected launch can restore local preferences/check the saved directory; it is not filesystem-free.

The DEBUG-only fixture is explicitly enabled by `--joycode-offline-ui-fixture`. It uses temporary local preferences, in-memory sessions/catalogs/history/active membership/pending permission, and synthetic fanout readiness/events. Its diagnostic owner stays disconnected. **Release was measured without the fixture argument; the fixture boundary was not changed.** Fixture idle is not production connected idle: it has no real SSE traffic and starts with empty history.

Both live-test opt-ins were removed from each child environment. No existing-service requests, `Service.ensure`, service lifecycle operations, provider calls, backend registration/config/database edits, commits, or optimized Release tests. Only the three exact app processes launched by the measurement script were terminated afterward. Unrelated user applications/windows were not closed or modified; no focus/visibility automation was performed.

## Method and results

Sequential direct executable launches from Python, without Xcode/debugger/XCTest instrumentation. One 70-second run per scenario, no user interactions. `ps -p PID -o time=` recorded cumulative process CPU each second. Interval mean = 100 × CPU-time delta / measured monotonic wall-time delta; **100% means one CPU core**, not the entire machine. `ps` CPU time has 0.01-second resolution; tiny differences and zero are quantized, not precise performance rankings. The first observation occurs just after launch, so the 0–10-second interval is an approximate startup window.

Each app was sampled at about 20 seconds for 5 seconds with a 10-ms sample interval. The 10–40-second interval includes sampling; the 40–70-second interval does not. Concurrent desktop activity was left untouched, and foreground/occlusion state was not independently controlled. These are bounded idle baselines, not a benchmark or burst/history acceptance test.

| Scenario | PID / local launch time | 0–10 s CPU / mean | 10–40 s CPU / mean | 40–70 s CPU / mean |
|---|---|---|---|---|
| Debug production disconnected | 61210 / 18:53:00 | 0.40 s / **4.00%** | 0.01 s / **0.033%** | 0.01 s / **0.033%** |
| Release production disconnected | 61411 / 18:54:15 | 0.31 s / **3.11%** | 0.02 s / **0.067%** | 0.00 s / **0.000%** |
| Debug offline fixture idle | 61576 / 18:55:30 | 0.41 s / **4.10%** | 0.03 s / **0.100%** | 0.04 s / **0.133%** |

### Stack evidence

There is **no measured hot application stack** in these idle captures:

- Debug disconnected: all 458 main-thread observations follow AppKit's event loop through `__CFRunLoopServiceMachPort` to `mach_msg2_trap`; worker observations end in `__workq_kernreturn`.
- Release disconnected: all 458 main-thread observations show the same wait chain; workers also wait.
- Debug fixture: all 457 main-thread observations show the same wait chain; workers also wait.
- NSEvent threads also wait in Mach messaging. The call graphs do not show repeated store refresh/reduction, SwiftUI rendering, decoding, or active task execution during the sampled interval.

These are wall-clock stack samples including blocked threads, **not CPU-weighted percentages**. Their interpretation as idle waits is corroborated by the process CPU deltas. Transient activity outside the 5-second captures, connected traffic and debugger/test behavior remain unmeasured.

## Diagnosis confidence and changes

High confidence that these particular standalone, disconnected/fixture runs did not sustain excessive CPU over their measured intervals. Both Debug and Release settle near zero; no meaningful sustained Debug-only penalty is established here. **Insufficient evidence to classify the original connected-idle complaint as tooling overhead versus application logic.** Earlier XCTest automation failures remain separate historical evidence, not an explanation.

Source inspection identified possible amplification sites only: broad root observation, publisher→main-queue→Task hops, composer context/draft publication, event-triggered authoritative rereads and per-render transcript identity work. No hot-stack or activity-count evidence implicates any of them. No speculative equality guards, event filtering, refresh suppression or subscription changes were made. R08/R09/R10 safety and one-subscription fanout remain unchanged.

Repository changes: this note and a link from the R11 sequencing hold. A measurement script and raw evidence were added only to the approved temporary artifact directory. No application/test/project changes; no before/after fix comparison or new regression-test counts exist.

## Exact checks and artifacts

Artifact root (`T` below):

`/private/var/folders/dg/dztwhk5n6rb9xr8jt3t0nkf00000gp/T/opencode/`

Commands actually run from the repository (variables below abbreviate the exact absolute paths):

```sh
T='/private/var/folders/dg/dztwhk5n6rb9xr8jt3t0nkf00000gp/T/opencode'
P="$T/joycode-hardening-derived/Build/Products"
ps -axo pid,ppid,%cpu,time,etime,comm | sort -k3 -nr | head -25
ps -axo pid,ppid,%cpu,time,etime,comm | grep -Ei 'Joycode|xcodebuild|XCTest|debugserver|swift-frontend'
xcodebuild -version
sw_vers
file "$P/Debug/Joycode.app/Contents/MacOS/Joycode" "$P/Release/Joycode.app/Contents/MacOS/Joycode"
python3 "$T/joycode-cpu-measure.py" joycode-cpu-debug-disconnected "$P/Debug/Joycode.app/Contents/MacOS/Joycode"
python3 "$T/joycode-cpu-measure.py" joycode-cpu-release-disconnected "$P/Release/Joycode.app/Contents/MacOS/Joycode"
python3 "$T/joycode-cpu-measure.py" joycode-cpu-debug-fixture "$P/Debug/Joycode.app/Contents/MacOS/Joycode" -- --joycode-offline-ui-fixture
```

All three measurement commands exited 0. Script strips both opt-ins and invokes `sample PID 5 10 -file PATH`; all three sampling logs report completion. Each prefix above has `-measure.json` (all 71 CPU observations, PID, command, intervals), `-sample.txt` (complete stack/image evidence), and `-app.log` (app output plus sampling completion). Primary read the complete call-graph sections and the sampling logs. Final process search returned no matching app/tooling processes (grep exit 1 means no matches). Existing untracked repository work was preserved.

No tests/builds were rerun: application source was unchanged, and the original report likely concerns a scenario that is outside current authorization. Future build/test work must reuse the exact R10 Xcode commands and keep Debug tests only; these measurements do not supersede its 537-unit/8-UI baseline.

## Stop boundary / next evidence needed

Stop here, before R11. To continue, obtain explicit approval for a bounded **connected-idle** profile: normal production connection discovery/info, SSE subscription and relevant read requests, but no prompt submission, permission reply, interrupt, provider execution, lifecycle action or configuration/database edit. Identify the actual hot Joycode PID and Debug/Release/launch mode while the symptom is present; record selected session/history size and event/read activity without private payloads. Capture CPU intervals and stacks then compare equivalent configurations. Alternatively, the user can supply a process sample and CPU reading from the affected app.

No live model test is authorized. If later separately authorized, it must use only provider `openrouter`, model `openrouter/free` (`openrouter/openrouter/free`), never Anthropic/OpenAI or fallback. P1 remains unaccepted; R11–R14 remain unfinished.

## Authorized follow-up — 2026-10-05 (in progress)

User authorized profiling, additional tests and thorough code inspection after the initial report. This extends scope to normal existing-service connection discovery/info, reads and SSE subscription only. No prompts, provider calls, mutations, service lifecycle operations or backend/configuration/database changes are authorized or used. R11 remains out of scope.

### Thorough source audit

Two fresh read-only leaf delegates audited transport/connection/event handling and state/composition separately. Primary inspected native views, searched for recurring timers/tasks and independently re-read the implicated transport, parser, owner, composer/selection bindings and execution event reducer. Neither audit found an autonomous idle polling or self-sustaining publication/request loop.

Concrete traffic-dependent costs, not a demonstrated CPU cause:

- `URLSessionEventSource` awaits bytes and creates `Data([byte])`/calls `SSEParser.append` per byte. This is a throughput cost, not spinning while no bytes arrive. Comment heartbeats are discarded before event JSON decoding/fanout.
- `ConnectionEventOwner` publishes diagnostic count/type for every decoded event, and `RootView` observes it broadly. Even unrelated-session/delta traffic can therefore invalidate presentation. Each event is still delivered through one owner/fanout; no filtering/suppression was added.
- Composer context refresh publishes context/draft/submission even if unchanged, after session/selection/context publisher hops. There is no reverse binding that makes these publications reschedule selection/session work by themselves.
- Status/history/permission events can sustain authoritative rereads only while invalidating traffic continues. Transcript has a 150-ms resync debounce; execution/permissions coalesce per flight. No error-driven autonomous retry/reconnect was found.
- Execution durable-sequence bookkeeping precedes family/session filtering and its aggregate dictionary can grow during a long-lived connection with many aggregates. Completed composer task handles/drafts also remain retained. These are retention/burst investigation candidates, not measured idle CPU defects; no unrelated cleanup was undertaken.
- Native views contain no `Timer`, `TimelineView`, repeating animation or polling loop. The project/session restore tasks are one-shot guarded; rename `onChange` syncs local draft state without dispatching a rename. Transcript per-render identity/structured-summary work scales with displayed content, but requires a render trigger.

### Profiling harness issue (preserved)

Direct AppleScript UI automation reported accessibility disabled. No permissions/settings were changed. A temporary Debug XCTest probe was compiled to activate a separately launched product and click Connect. Its first build failed on main-actor-isolated `label` key paths; corrected temporary code compiled in `joycode-cpu-probe-build-2.log`. The runner then failed to initialize UI automation (`Timed out while enabling automation mode`, exit 65, `joycode-cpu-debug-connected-ui.log`). It never reached the test/Connect action; this supplied no connected CPU evidence. The original failed build log is retained as `joycode-cpu-probe-build.log`.

The temporary UI probe was removed. Standalone profiling instead uses a temporary explicit `--joycode-cpu-read-only-connect` launch hook that invokes the same owner `connect()` action, plus finite payload-free state snapshots and HTTP request-kind/method counts. It adds no subscription, provider call or recurring refresh, and does not change Release's DEBUG-fixture boundary. The temporary hook/counters will be removed and both configurations rebuilt before handoff.

Standalone instrumented Debug and Release builds succeeded (`joycode-cpu-debug-instrumented-build.log`, `joycode-cpu-release-instrumented-build.log`), using the same R10 project/scheme/destination/derived-data commands with only `build`, not Release tests. No unit/UI suite runs overlap the CPU captures.

### Connected measurements — completed 2026-10-05

All runs launch the exact app executable directly via Python (no Xcode/debugger/XCTest), strip both live-test opt-ins, sample the exact PID with `sample PID 5 10`, terminate only the owned process, and report 100% = one core. `ps` CPU time has 0.01 s resolution; one-second buckets are quantized interval averages.

First connected Debug (PID 63306, 70 s, snapshots at t=10/40 only in the built product): 6.00% / 0.233% / 2.167% for 0–10 / 10–40 / 40–70 s. Connected 2.0.20, 1 event at t=10 and 7 at t=40, no session/messages, one `get info` request. Settled one-second spikes up to **14.98%** (49–50 s), 10.06% (63–64 s), 8.03% (53–54 s) recurred outside the single t=20–25 sample, which showed 461 waiting main-thread observations. **The spike cause was not captured; shared-stream traffic was only a hypothesis.**

Connected Release (PID 63538, 180 s, samples at t=20 and t=165): 4.202% / 0.533% / 0.336%, 1.05 s total. Connected 2.0.20, events 3 / 29 / 54 at t=10 / 40 / 70, no session/messages, one `get info` request. Largest settled bucket was **8.97%** (171–172 s); no 15% spike recurred. Early sample: 456 waiting main-thread observations. Late sample: 412/421 main mach waits plus 2 cooperative-queue observations in `URLSessionEventSource.openSubscription` → `SSEParser.append` → JSON decode (`EventEnvelope`/`EventJSONValue`). That is sparse traffic-dependent work, not a hot idle loop. Release image UUID `BDB2FBB5-7C87-30D2-B3F2-68FA17E5100F`, ARM64. Artifacts: `joycode-cpu-release-connected-standalone-measure.json/-app.log/-sample.txt/-sample-late.txt`.

Extended connected Debug (PID 64503, 180 s, rebuilt with event-timing + snapshots at t=10/40/70/100/130/160, plus a 135 s continuous sample over t≈40–175): 7.204% / 0.100% / **0.043%**, 0.81 s total. Connected 2.0.20, events 19 / 25 / 26 / 26 / 26 / 26, no session/messages, one `get info` request. Event timing (payload-free type + `systemUptime` count) shows an initial burst (counts 2–19 within ~4 s: `session.reasoning/tool/step/text/usage/execution`), `provider/model.updated` at ~38–42 s, `session.viewed` at ~68.7 s, then silence to t=180. Python `monotonic()` and Swift `systemUptime` agree within ~1 s (first event at elapsed ~1.03 s). Only settled buckets ≥3% were 3.99% (1–2 s), 3.00% (3–4 s, inside the burst) and 3.00% (68–69 s, aligned with `session.viewed`). **No 10–15% spike recurred.** Early (458) and late (457) main-thread observations are waits; the continuous 12,399-observation main thread is 12,385 mach waits with the remainder SkyLight menu-bar work, workers are `__workq_kernreturn`, and no Joycode application frame appears beyond the main entry. Debug dylib UUID for this run: `A106C493-7F2F-38E0-AA91-F62B51B88976`. Artifacts: `joycode-cpu-debug-connected-extended-measure.json/-app.log/-sample.txt/-sample-late.txt/-sample-continuous.txt`.

### Diagnosis — no application-logic defect demonstrated

No autonomous polling/reconnect/retry loop was found, the SSE reader blocks for bytes, and all long captures settle near zero with waiting stacks — including 135 s of continuous connected-idle sampling with live event traffic. Per-byte SSE construction, per-event diagnostic publication with broad root observation, and event-driven rereads remain traffic-dependent cost hypotheses with only the 2-observation Release decode sample as direct evidence; they do not explain a sustained idle defect and no speculative fix was made. **The original complaint is unreproduced and the brief ~15% spikes from the first connected Debug run remain unexplained.** Do not cite this as a Debug-overhead diagnosis.

### Cleanup and regression — completed 2026-10-05

All temporary instrumentation was removed from `App/JoycodeApp.swift`, `API/HTTP/HTTPTransport.swift`, and `State/ConnectionEventOwner/ConnectionEventOwner.swift`; `grep` confirms no `CPU_PROBE`, `--joycode-cpu-read-only-connect`, or temporary probe text remains in `App/API/State/Tests/UITests`, and the earlier temporary XCTest probe stays removed. Failed profiling artifacts (UI automation timeout, first probe build failure) are preserved as evidence in the artifact root; the measurement scripts were left there and not added to the repo. Clean separate Debug and Release `build` commands both succeed (`joycode-cpu-clean-debug-build.log`, `joycode-cpu-clean-release-build.log`); `strings` finds zero probe markers in the clean Debug executable, Debug dylib, or Release executable. Offline Debug unit regression on the cleaned source passes: **537 executed, 1 live skip, 0 failures**, exit 0 (`joycode-cpu-clean-debug-unit.log`). No Release test was run. No prompts, provider calls, mutations, lifecycle actions, commits, or unrelated app/window changes occurred. R11–R14 remain unfinished; P1 is not accepted.
