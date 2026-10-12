# pi-durable 1.1.0 event fixtures

Real `watchEvents()` output from `@earendil-works/pi-durable` 1.1.0, recorded with the faux provider from `@earendil-works/pi-ai` 1.1.0. No API key or network is involved. Nothing in these files is hand-written or edited.

## Reproducing

```sh
cd scratch/recorder
pnpm install          # from the project root's workspace; all @earendil-works packages pinned to 1.1.0
pnpm run record       # node record.ts ../../fixtures/durable-1.1.0
python3 -I ../tools/check_fixtures.py ../../fixtures/durable-1.1.0
python3 -I ../tools/check_citations.py ../../docs/protocol.md ../../fixtures/durable-1.1.0
```

Line numbers can move when a scenario is re-recorded, because the number of update batches varies. After re-recording, run `check_citations.py` and fix any reference in `docs/protocol.md` whose line no longer shows what the document says.

Node 24.11.1 runs the TypeScript sources directly. Each scenario opens its own Harness, so IDs restart in every file. Re-recording changes timestamps, `t` values, the faux `api` string, and how text splits into deltas, because faux picks token sizes at random. That also changes how many `message_update` and `tool_execution_update` batches appear. All other events and every ID stay the same, which I compared against a second recording. `check_fixtures.py` asserts the behaviour each scenario exists for, and passed on this recording and on two re-recordings.

The recorder lives in `scratch/recorder`:

- `lib.ts`: the faux model `faux/faux-1` (reasoning on, 50 tokens per second, so one answer spans several 100 ms partial commits), the three tools below, and the JSONL writer.
- `record.ts`: one function per scenario.
- `crash-child.ts`: the two processes of scenario 11.

Tools, all in one extension named `fixture-tools`:

- `count {n, delayMs?}`: streams `1\n` to `n\n` through `api.output()`, one line per `delayMs` (default 80), sets `details: {counted: n}`, and honours abort.
- `lookup {city}`: returns a population after 30 ms with `details: {city, population}`.
- `delete_file {path}`: only used where a hook blocks or approves it.

## Line format

One JSON object per line. `t` is milliseconds since the scenario started. Each line has exactly one of these keys besides `t`:

| Key | Meaning |
|---|---|
| `snapshot` | `stream.snapshot` at attachment, exactly as `watchEvents()` returned it. |
| `batch` | One listener call: the events of one commit, in delivery order. A batch can itself hold a `snapshot` event after overflow (scenario 14). |
| `note` (+ `data`) | Something the recorder did, such as submitting a steer or calling `abort()`. Not part of the stream. A note is written after the call returns, so batches the call caused can appear before it. |
| `end` | The `WatchEnd` value when the stream closed. |

## Scenarios

| File | How it was produced |
|---|---|
| `01-plain-answer` | Thinking level `medium`. One answer with a thinking block and a text block. Shows `thinking_delta`, then `text_start`, then `text_delta`. |
| `02-tool-round` | Answer = text plus one `count {n: 5}` call, then a final answer. Tool output arrives as `{set}` first, then `{append}`. |
| `03-parallel-tools` | `toolExecution: "parallel"`. One answer with `count {n: 6}`, `count {n: 3}` and `lookup {Porto}`. Their updates interleave and they finish out of call order. |
| `04-steer-during-tools` | `count {n: 8}` runs. On its first output update the recorder submits `whenBusy: "steer"`. The steer is queued, placed after the tool round as a `pi.user` entry in the same run, and `run_end` lists both inputs. |
| `05-follow-up-while-busy` | On the first `message_update` of a long answer, the recorder submits a second input with the default `whenBusy` (follow-up). It is placed when the first run ends and starts a second run. |
| `06-abort-mid-generation` | On the first `message_update` the recorder calls `root.abort()`. The partial becomes an assistant entry with `stopReason: "aborted"`. The input settles `unanswered`, reason `aborted`. |
| `07-abort-mid-tool` | `count {n: 40}`. Once the output reaches `3\n`, `root.abort()`. The tool gets an error result with diagnostic code `aborted` and the output so far. No further generation runs. |
| `08-blocked-tool` | A `beforeTool` hook blocks `delete_file`. The answer calls `lookup` and `delete_file` together. The blocked call gets only `tool_execution_end` (no start), with diagnostic code `blocked`. The model then answers. |
| `09-manual-compaction` | Three Q&A turns with compaction `enabled: false` and `keepRecentTokens: 200`, then attach, then `root.compact("Keep the city names")` while idle. The snapshot holds the history. The summary arrives as a `pi.compaction` entry, whose model message has role `user`, plus a `submission` with requestId `compaction:<taskId>`. |
| `10-late-join` | A second watcher attached while `count {n: 10}` was at `5\n`. The snapshot holds the running tool slot and its output so far. |
| `10-late-join.mid-answer` | A third watcher on the same run, attached during the final answer. The snapshot holds `generation.message`, the committed partial. |
| `10-late-join.full` | A watcher on the same run, attached before submitting. All three files reach the same final state. |
| `11-crash-and-resume` | Process 1 opens a SQLite store, submits `req-11` and runs `count {n: 20}`. The parent sends it SIGKILL when output reaches `4\n`. Process 2 reopens the store and attaches (the snapshot shows the run and the tool slot still `running` with `1\n` to `4\n`). It resubmits `req-11`, gets the same submission ID back, and calls `resume()`. The tool is not replay-safe, so it gets an error result with diagnostic code `interrupted`, and the model answers. Lines from both processes are stamped on the parent's clock. |

### Extra scenarios, not in the brief

| File | Why |
|---|---|
| `12-approval-hook` | pi-durable has no approval concept. This shows the nearest building block: an async `beforeTool` hook that waits 600 ms for an outside decision, then approves. While the hook waits, the stream emits nothing at all. The assistant entry with the tool call is the last event until `tool_execution_start`. A server that offers approvals has to emit its own "needs approval" events. |
| `15-approval-crash-resume` | Recorded after the protocol review. Process 1 opens a SQLite store and submits `req-15`. Its `beforeTool` hook for `delete_file` waits forever, and the parent kills it with SIGKILL once the hook is entered. Process 2 reopens the store and calls `resume()`. The hook runs again (the two "hook entered" notes carry different pids), the recorder approves after 300 ms, and the tool runs. The snapshot in process 2 shows the waiting call as a `pending` slot. |
| `16-approval-abort` | Recorded after the protocol review. A `beforeTool` hook races a decision that never comes, its context's abort signal, and a 3 s fallback. The recorder calls `root.abort()` 300 ms after the hook is entered. The abort signal ends the wait within a millisecond. The hook returns a block, but pi-durable writes its own result with diagnostic `aborted`, and the input settles `unanswered`, reason `aborted`. |
| `13-configure-and-reset` | Evidence for the `configure` and `reset` commands. `configure()` emits `agent_changed` with the whole stored agent. Clearing a field with `null` removes it from the next `agent_changed`. `reset(handoff)` appends a `pi.reset` entry whose model message is the handoff as a user message. Its submission has no `requestId`. |
| `14-overflow-snapshot` | The listener stalls for 2 s on its first batch while `count {n: 160}` commits output every few ms. More than 100 batches back up, so the pending ones are replaced by one batch holding a single `snapshot` event, followed by the batches committed after it. This is the "falls behind" case. |

## What faux could not produce

- **Cost.** Faux reports every `cost` field as 0 (`pi-ai/dist/providers/faux.js`, `withUsageEstimate`), whatever the model definition says. Token counts are real estimates, so `usage_changed` and the snapshot's `usage` have true shapes and token numbers but zero cost. I did not invent cost values.
- **Retries and deferred polling.** `auto_retry_start`, `auto_retry_end` and `deferred_poll` do not appear. Faux can return error messages and deferred handles, so these could be recorded later if the protocol needs them.
- **`task_failed`.** No scenario faults a task.

Everything else in the brief's list was recorded as asked.

## Shapes worth knowing

- Entry, submission, task and conversation IDs are JSON numbers in both memory and SQLite storage. Tool call IDs are strings.
- The first event of a tool result is `tool_execution_end`, followed directly by that result's `message_start` and `message_end`.
- A `pi.system` entry appears before the first generation of a run whenever the prompt or the offered tools changed. Its `toolsAdded` lists full tool schemas.
- A `ToolSlot` in a snapshot has no arguments. They are in the tool call block of the preceding assistant entry.
- `message_update` changes refer to `contentIndex` in the in-flight message. `toolcall_delta` paths are relative to the call's `arguments`. A `block` change replaces a whole block.
