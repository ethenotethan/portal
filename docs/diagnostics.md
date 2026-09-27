# Diagnostics: the session health watchdog

Portal has shown a terminal state after hours of use: artifact scrolls and
sessions go bad and only a restart recovers. The cause is not known. The
session health watchdog exists so the next occurrence produces evidence
instead of a restart.

## What is recorded

Every sampling interval (30 s by default; 15/30/60 s in Settings → Diagnostics)
`SessionHealthMonitor` takes one `SessionHealthSample` and writes it as one line
to `~/Library/Logs/Portal/portal.log` under the `Health` category:

```
[info] Health: uptime_s=1830 mem_mb=612 threads=71 fds=143 cpu_pct=4 hangs=0 storms=0 longest_hang_ms=0 gateway=connected pending_rpc=0 reconnect_attempt=0 events=17 rtt_ms=12 chat_vms=2 sessions=1 webviews=3 inline_html=2 artifact_canvases=n/a artifacts=6 artifact_relayouts=0 webview_reloads=0 relayout_guard_trips=n/a
```

Fixed key order, `key=value`, `n/a` for anything the host or build cannot read.
Plot it with `grep " Health: " ~/Library/Logs/Portal/portal.log`.

| Field | Source |
|---|---|
| `mem_mb`, `threads`, `cpu_pct` | `task_info(TASK_VM_INFO)` physical footprint, mach thread list (`PerfSample`) |
| `fds` | entries in `/dev/fd` |
| `hangs`, `storms`, `longest_hang_ms` | `MainThreadWatchdog.stallStatistics()` — counts since launch, thresholds unchanged (250 ms) |
| `gateway`, `pending_rpc`, `reconnect_attempt`, `rtt_ms` | `GatewayClient.diagnosticSnapshot()` and the wrapper's last ping |
| `events` | gateway events received since the previous sample |
| `chat_vms`, `webviews`, `inline_html` | `LiveObjectRegistry`: `ChatViewModel` init/deinit, every `WKWebView` construction (sentinel unregisters on dealloc), every `InlineHTMLView` coordinator |
| `sessions`, `artifacts` | `SessionListViewModel.sessions.count`, `ArtifactStore.artifacts.count` |
| `artifact_relayouts`, `webview_reloads` | `HealthCounters` bumped in `ArtifactCanvasView`'s relayout `onChange`s and `InlineHTMLView`'s `loadHTMLString` |
| `artifact_canvases`, `relayout_guard_trips` | not instrumented yet (`n/a`); the canvas is a value type and the relayout guard is a test-time rule |

## Degraded-state rules

`SessionHealthAssessor` runs over the last two hours of samples after every
tick. Nothing fires in the first two minutes of uptime: a launch that resumes a
thousand sessions hangs and balloons on purpose (the first real run recorded
1.6 GB and nine hangs in 71 s), and the run's first bundle must not be spent on
it — the samples are still logged. Thresholds live in
`SessionHealthAssessor.Thresholds`, one comment each:

| Rule | Fires when |
|---|---|
| `memory-ceiling` | footprint > 2 GiB |
| `memory-growth` | footprint grew > 60 % within the last 30 min, between samples ≥ 10 min apart |
| `main-thread-hangs` | ≥ 3 hangs in the last 5 min (counted against the pre-window baseline) |
| `pending-rpc-pool` | ≥ 25 pending requests for two consecutive samples |
| `webviews-alive` / `webviews-growing` | > 10 `WKWebView`s alive, or the count grew every sample for 10 samples |
| `chat-viewmodel-leak` | live `ChatViewModel`s > open sessions + 2 (the page docks) |
| `thread-count` | > 150 threads |
| `event-backlog` | > 500 gateway events in one interval |
| `file-descriptors` | > 900 open descriptors |

## Diagnostic bundles

When any rule fires (one bundle per 10 minutes) or when you ask, a folder is
written under `~/Library/Logs/Portal/diagnostics/<timestamp>/`:

- `health.json` — the last 60 samples and the findings
- `gateway.json` — the gateway client's debug snapshot: connection, pending requests and their methods, recent events, dropped events
- `registries.json` — live object counts and peaks, and the churn counters
- `log-tail.txt` — the last 2,000 lines of `portal.log`
- `threads.txt` — the capturing thread's backtrace and, on macOS, `sample <pid> 3` for every thread (when `sample` refuses, the reason is written instead)
- `README.txt` — what triggered it, what each file is, what to do

The log gets one `[error] Health: degraded state detected (…); diagnostics
written to …` line and a notification names the folder.

## Capturing on demand

- macOS: **Help ▸ Capture Diagnostics Now** (⌘⌥⇧D) — writes a bundle and reveals it in Finder.
- Settings → Diagnostics → **Capture Diagnostics Now** (macOS and iOS), next to the interval picker and the latest sample.
- Launch argument `--capture-diagnostics-on-launch` writes one bundle after the first sample (used to prove the path end to end).

## What to do with a bundle

Send the whole folder to whoever is diagnosing. If the app is still in the bad
state, also take a manual sample in Terminal, which is the tool that has found
every beachball so far:

```
sample Portal 5 -file ~/Desktop/portal-sample.txt
```

and include that file. A bundle's `health.json` shows which numbers moved in
the hours before the state; `threads.txt` shows where the main thread was when
it was captured.
