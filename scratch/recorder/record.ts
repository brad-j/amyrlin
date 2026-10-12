// Records watchEvents() output for each fixture scenario as JSON lines.
// Usage: node record.ts <outDir> [scenario...]   (no names: all scenarios)
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import type { TranscriptContext } from "@earendil-works/pi-ai";
import { fauxAssistantMessage, fauxText, fauxThinking, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { type AgentEvent, type Harness, hook, MemoryStorage, ToolTask } from "@earendil-works/pi-durable";
import { context, lastUser, open, pause, Recorder } from "./lib.ts";

const here = fileURLToPath(new URL(".", import.meta.url));
const [outDir = join(here, "out"), ...only] = process.argv.slice(2);

const is = (type: AgentEvent["type"]) => (event: AgentEvent) => event.type === type;
const toolCalls = (...calls: ReturnType<typeof fauxToolCall>[]) => fauxAssistantMessage(calls, { stopReason: "toolUse" });

/** Wait until the harness is idle, let the last batch reach the listener, then stop and close. */
async function finish(harness: Harness, ...streams: { stop(): Promise<unknown> }[]) {
	await harness.waitForIdle(context);
	await pause(20);
	for (const stream of streams) await stream.stop();
	await harness.close(context);
}

type Output = Record<string, Recorder>;
const scenarios: Record<string, () => Promise<Output>> = {
	async "01-plain-answer"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			agent: { thinkingLevel: "medium" },
			responses: [
				fauxAssistantMessage([
					fauxThinking("The user wants the capital of Portugal. That is Lisbon, a city on the Tagus."),
					fauxText("The capital of Portugal is Lisbon. It sits on the estuary of the Tagus river, near the Atlantic coast."),
				]),
			],
		});
		const stream = await rec.attach(harness, root.id);
		const submission = await root.submit({ type: "input", content: "What is the capital of Portugal?", requestId: "req-01" }, context);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-01" });
		await finish(harness, stream);
		return { "": rec };
	},

	async "02-tool-round"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			responses: [
				fauxAssistantMessage([fauxText("I'll count to five."), fauxToolCall("count", { n: 5 }, { id: "call-1" })], {
					stopReason: "toolUse",
				}),
				fauxAssistantMessage([fauxText("Counted from one to five.")]),
			],
		});
		const stream = await rec.attach(harness, root.id);
		const submission = await root.submit({ type: "input", content: "Count to five.", requestId: "req-02" }, context);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-02" });
		await finish(harness, stream);
		return { "": rec };
	},

	async "03-parallel-tools"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			settings: { toolExecution: "parallel" },
			responses: [
				toolCalls(
					fauxToolCall("count", { n: 6, delayMs: 70 }, { id: "call-a" }),
					fauxToolCall("count", { n: 3, delayMs: 90 }, { id: "call-b" }),
					fauxToolCall("lookup", { city: "Porto" }, { id: "call-c" }),
				),
				fauxAssistantMessage([fauxText("Both counts finished, and Porto has about 232,000 people.")]),
			],
		});
		const stream = await rec.attach(harness, root.id);
		const submission = await root.submit({ type: "input", content: "Count twice and look up Porto.", requestId: "req-03" }, context);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-03" });
		await finish(harness, stream);
		return { "": rec };
	},

	async "04-steer-during-tools"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			responses: [
				toolCalls(fauxToolCall("count", { n: 8, delayMs: 100 }, { id: "call-1" })),
				(transcript) => fauxAssistantMessage(`Counted to eight. You said: "${lastUser(transcript)}".`),
			],
		});
		const stream = await rec.attach(harness, root.id);
		const first = await root.submit({ type: "input", content: "Count to eight.", requestId: "req-04a" }, context);
		rec.note("submitted", { submissionId: first.id, requestId: "req-04a" });
		await rec.waitFor(is("tool_execution_update"));
		const steer = await root.submit(
			{ type: "input", content: "Stop at eight and say so.", whenBusy: "steer", requestId: "req-04b" },
			context,
		);
		rec.note("steer submitted", { submissionId: steer.id, requestId: "req-04b" });
		await finish(harness, stream);
		return { "": rec };
	},

	async "05-follow-up-while-busy"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			responses: [
				fauxAssistantMessage(
					"Lisbon has seven hills, and the old trams climb most of them. Start in Alfama, walk up to the castle, then take the 28 tram west.",
				),
				(transcript) => fauxAssistantMessage(`For "${lastUser(transcript)}": try Time Out Market for lunch.`),
			],
		});
		const stream = await rec.attach(harness, root.id);
		const first = await root.submit({ type: "input", content: "Plan a morning in Lisbon.", requestId: "req-05a" }, context);
		rec.note("submitted", { submissionId: first.id, requestId: "req-05a" });
		await rec.waitFor(is("message_update"));
		const followUp = await root.submit({ type: "input", content: "Where should we eat?", requestId: "req-05b" }, context);
		rec.note("follow-up submitted", { submissionId: followUp.id, requestId: "req-05b" });
		await finish(harness, stream);
		return { "": rec };
	},

	async "06-abort-mid-generation"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			responses: [
				fauxAssistantMessage(
					"Here is a long history of Lisbon. It begins with Phoenician traders, then Romans, then Moors, then the Reconquista in 1147, the earthquake of 1755, and the rebuilding under Pombal.",
				),
			],
		});
		const stream = await rec.attach(harness, root.id);
		const submission = await root.submit({ type: "input", content: "Tell me the history of Lisbon.", requestId: "req-06" }, context);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-06" });
		await rec.waitFor(is("message_update"));
		rec.note("abort requested");
		await root.abort(context);
		rec.note("abort resolved");
		await finish(harness, stream);
		return { "": rec };
	},

	async "07-abort-mid-tool"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			responses: [toolCalls(fauxToolCall("count", { n: 40, delayMs: 80 }, { id: "call-1" }))],
		});
		const stream = await rec.attach(harness, root.id);
		const submission = await root.submit({ type: "input", content: "Count to forty.", requestId: "req-07" }, context);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-07" });
		await rec.waitFor((event) => event.type === "tool_execution_update" && JSON.stringify(event).includes("3\\n"));
		rec.note("abort requested");
		await root.abort(context);
		rec.note("abort resolved");
		await finish(harness, stream);
		return { "": rec };
	},

	async "08-blocked-tool"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			hooks: [
				hook(ToolTask, {
					beforeTool: (call) => (call.name === "delete_file" ? { block: "delete_file is not allowed here" } : undefined),
				}),
			],
			responses: [
				toolCalls(
					fauxToolCall("lookup", { city: "Braga" }, { id: "call-ok" }),
					fauxToolCall("delete_file", { path: "/tmp/notes.txt" }, { id: "call-blocked" }),
				),
				fauxAssistantMessage("Braga has about 193,000 people. I was not allowed to delete the file."),
			],
		});
		const stream = await rec.attach(harness, root.id);
		const submission = await root.submit(
			{ type: "input", content: "Look up Braga and delete /tmp/notes.txt.", requestId: "req-08" },
			context,
		);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-08" });
		await finish(harness, stream);
		return { "": rec };
	},

	async "09-manual-compaction"() {
		const rec = new Recorder();
		const respond = (transcript: TranscriptContext) => {
			const first = transcript.messages[0];
			if (first?.role === "system" && typeof first.content === "string" && first.content.includes("summar")) {
				return fauxAssistantMessage("## Goal\nPlan a week in Portugal: Lisbon, Porto, Braga.");
			}
			return fauxAssistantMessage(`About "${lastUser(transcript)}": ${"details ".repeat(120)}`);
		};
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			faux: { tokensPerSecond: 2000 },
			settings: { compaction: { enabled: false, keepRecentTokens: 200 } },
			responses: Array.from({ length: 10 }, () => respond),
		});
		// Build some history before attaching, so the snapshot holds it.
		for (const [i, question] of ["Where should we stay in Lisbon?", "What about Porto?", "Is Braga worth a day?"].entries()) {
			await (await root.submit({ type: "input", content: question, requestId: `req-09-${i}` }, context)).wait(context);
		}
		const stream = await rec.attach(harness, root.id);
		const taskId = await root.compact("Keep the city names", context);
		rec.note("compact requested", { taskId });
		const settled = await harness.waitForTask(taskId, context);
		rec.note("compaction task settled", { outcome: settled.state.outcome });
		await finish(harness, stream);
		return { "": rec };
	},

	async "10-late-join"() {
		const full = new Recorder();
		const late = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			responses: [
				toolCalls(fauxToolCall("count", { n: 10, delayMs: 100 }, { id: "call-1" })),
				fauxAssistantMessage([fauxText("Counted to ten, and this answer streams slowly enough to watch it arrive.")]),
			],
		});
		const midAnswer = new Recorder();
		const fullStream = await full.attach(harness, root.id);
		const submission = await root.submit({ type: "input", content: "Count to ten, then tell me.", requestId: "req-10" }, context);
		full.note("submitted", { submissionId: submission.id, requestId: "req-10" });
		await full.waitFor((event) => event.type === "tool_execution_update" && JSON.stringify(event).includes("5\\n"));
		full.note("late watcher attaching mid-tool");
		const lateStream = await late.attach(harness, root.id);
		late.note("attached mid-tool; the full stream of the same run is 10-late-join.full.jsonl");
		await full.waitFor(
			(event) => event.type === "message_update" && event.changes.some((change) => change.type === "text_delta"),
		);
		full.note("late watcher attaching mid-answer");
		const midAnswerStream = await midAnswer.attach(harness, root.id);
		midAnswer.note("attached mid-answer; the full stream of the same run is 10-late-join.full.jsonl");
		await finish(harness, fullStream, lateStream, midAnswerStream);
		return { "": late, ".mid-answer": midAnswer, ".full": full };
	},

	async "11-crash-and-resume"() {
		const rec = new Recorder();
		const dir = await mkdtemp(join(tmpdir(), "amyrlin-crash-"));
		const db = join(dir, "session.sqlite");
		rec.note("process 1: open SQLite store and submit", { store: "session.sqlite" });
		await child(rec, ["run", db], (line) => /"append":"[^"]*4\\n/.test(line));
		rec.note("process 2: reopen the same store, attach, resubmit req-11, resume()");
		await child(rec, ["resume", db]);
		return { "": rec };
	},

	// Not in the brief's list: a listener that falls more than 100 batches behind gets a `snapshot` event in a batch.
	async "14-overflow-snapshot"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			settings: { progress: { outputIntervalMs: 1 } },
			responses: [
				toolCalls(fauxToolCall("count", { n: 160, delayMs: 4 }, { id: "call-1" })),
				fauxAssistantMessage("Counted to 160."),
			],
		});
		const stream = await rec.attach(harness, root.id, { stallFirstBatchMs: 2_000 });
		const submission = await root.submit({ type: "input", content: "Count to 160 quickly.", requestId: "req-14" }, context);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-14" });
		await harness.waitForIdle(context);
		// Stop only after the stalled listener has drained what it was holding.
		await pause(2_500);
		await finish(harness, stream);
		return { "": rec };
	},

	// Not in the brief's list: evidence for approvals, which pi-durable has no concept of. A beforeTool hook awaits an
	// outside decision; the stream shows what a client sees (and does not see) while the hook waits.
	async "12-approval-hook"() {
		const rec = new Recorder();
		let answer!: (verdict: "approve" | "deny") => void;
		const verdict = new Promise<"approve" | "deny">((resolve) => {
			answer = resolve;
		});
		let entered!: () => void;
		const hookEntered = new Promise<void>((resolve) => {
			entered = resolve;
		});
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			hooks: [
				hook(ToolTask, {
					beforeTool: async (call) => {
						if (call.name !== "delete_file") return undefined;
						entered();
						return (await verdict) === "approve" ? undefined : { block: "The user denied this call" };
					},
				}),
			],
			responses: [
				toolCalls(fauxToolCall("delete_file", { path: "/tmp/notes.txt" }, { id: "call-1" })),
				fauxAssistantMessage("Deleted /tmp/notes.txt."),
			],
		});
		const stream = await rec.attach(harness, root.id);
		const submission = await root.submit({ type: "input", content: "Delete /tmp/notes.txt.", requestId: "req-12" }, context);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-12" });
		await hookEntered;
		rec.note("beforeTool hook entered; waiting for a decision", { toolCallId: "call-1" });
		await pause(600);
		rec.note("approved");
		answer("approve");
		await finish(harness, stream);
		return { "": rec };
	},

	// Not in the brief's list: does an approval survive a crash? Process 1 is killed while its beforeTool hook waits.
	// Process 2 reopens and resumes; the file shows whether the hook runs again (protocol section 8).
	async "15-approval-crash-resume"() {
		const rec = new Recorder();
		const dir = await mkdtemp(join(tmpdir(), "amyrlin-approval-crash-"));
		const db = join(dir, "session.sqlite");
		rec.note("process 1: open SQLite store and submit", { store: "session.sqlite" });
		await child(rec, ["approval-run", db], (line) => line.includes("beforeTool hook entered"));
		rec.note("process 2: reopen the same store, attach, resume()");
		await child(rec, ["approval-resume", db]);
		return { "": rec };
	},

	// Not in the brief's list: does abort() reach a beforeTool hook that waits for a decision? The hook races the
	// decision, its context's abort signal, and a 3 s fallback, and notes which one ended the wait.
	async "16-approval-abort"() {
		const rec = new Recorder();
		let entered!: () => void;
		const hookEntered = new Promise<void>((resolve) => {
			entered = resolve;
		});
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			hooks: [
				hook(ToolTask, {
					beforeTool: async (call, _api, ctx) => {
						if (call.name !== "delete_file") return undefined;
						entered();
						const signal = ctx.abortSignal;
						const outcome = await Promise.race([
							new Promise<string>((resolve) => {
								if (signal === undefined) return;
								if (signal.aborted) resolve("abort signal (already aborted)");
								signal.addEventListener("abort", () => resolve("abort signal"), { once: true });
							}),
							pause(3_000).then(() => "3 s fallback, no abort signal"),
						]);
						rec.note("hook wait ended", { by: outcome, hasSignal: signal !== undefined });
						return { block: "The approval was cancelled" };
					},
				}),
			],
			responses: [toolCalls(fauxToolCall("delete_file", { path: "/tmp/notes.txt" }, { id: "call-1" }))],
		});
		const stream = await rec.attach(harness, root.id);
		const submission = await root.submit({ type: "input", content: "Delete /tmp/notes.txt.", requestId: "req-16" }, context);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-16" });
		await hookEntered;
		rec.note("beforeTool hook entered; waiting for a decision", { toolCallId: "call-1" });
		await pause(300);
		rec.note("abort requested");
		await root.abort(context);
		rec.note("abort resolved");
		await finish(harness, stream);
		return { "": rec };
	},

	// Not in the brief's list: evidence for configure (agent_changed) and reset (pi.reset), both v1 commands.
	async "13-configure-and-reset"() {
		const rec = new Recorder();
		const { harness, root } = await open({
			storage: new MemoryStorage(),
			responses: [fauxAssistantMessage("Hello."), (transcript) => fauxAssistantMessage(`Starting fresh: "${lastUser(transcript)}"`)],
		});
		const stream = await rec.attach(harness, root.id);
		await (await root.submit({ type: "input", content: "Hi.", requestId: "req-13a" }, context)).wait(context);
		rec.note("configure", { thinkingLevel: "high", cwd: "/work/repo", instructions: "Be brief." });
		await root.configure({ thinkingLevel: "high", cwd: "/work/repo", instructions: "Be brief." }, context);
		rec.note("reset with handoff");
		await root.reset("We were planning a trip to Portugal.", context);
		await (await root.submit({ type: "input", content: "Continue.", requestId: "req-13b" }, context)).wait(context);
		rec.note("configure clears thinkingLevel", { thinkingLevel: null });
		await root.configure({ thinkingLevel: null }, context);
		await finish(harness, stream);
		return { "": rec };
	},
};

/** Run crash-child.ts, re-stamping its lines on our clock. `killWhen` sends SIGKILL at the first matching line. */
function child(rec: Recorder, args: string[], killWhen?: (line: string) => boolean): Promise<void> {
	return new Promise((resolve, reject) => {
		const proc = spawn(process.execPath, [join(here, "crash-child.ts"), ...args], { stdio: ["ignore", "pipe", "inherit"] });
		let killed = false;
		createInterface({ input: proc.stdout }).on("line", (line) => {
			if (killed) return;
			const { t: _t, ...rest } = JSON.parse(line);
			rec.write(rest);
			if (killWhen?.(line)) {
				killed = true;
				proc.kill("SIGKILL");
				rec.note("process 1 killed with SIGKILL", { pid: proc.pid });
			}
		});
		proc.on("exit", (code, signal) => {
			if (killWhen !== undefined && !killed) reject(new Error("child finished before the kill point"));
			else if (killWhen === undefined && code !== 0) reject(new Error(`child exited ${code ?? signal}`));
			else resolve();
		});
	});
}

async function main() {
	await mkdir(outDir, { recursive: true });
	const names = only.length > 0 ? only : Object.keys(scenarios);
	for (const name of names) {
		const run = scenarios[name];
		if (run === undefined) throw new Error(`unknown scenario ${name}`);
		const outputs = await Promise.race([
			run(),
			pause(30_000).then(() => {
				throw new Error(`${name} timed out`);
			}),
		]);
		for (const [suffix, rec] of Object.entries(outputs)) {
			const file = join(outDir, `${name}${suffix}.jsonl`);
			await writeFile(file, `${rec.lines.join("\n")}\n`);
			console.error(`${file}: ${rec.lines.length} lines`);
		}
	}
}

await main();
