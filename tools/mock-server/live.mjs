// Scripted live conversations for the mock server. A fake model answers each input according to its text:
// "count" runs a streaming count tool, "delete" asks for approval first, "long" writes a long answer.
// Events follow docs/protocol.md section 7; state follows sections 4 and 6.1.

export const MODELS = [
	{ provider: "mock", modelId: "mock-1", name: "Mock 1", reasoning: true, thinkingLevels: ["off", "low", "medium", "high"], contextWindow: 200_000, maxTokens: 8_000, input: ["text"], available: true },
	{ provider: "mock", modelId: "mock-fast", name: "Mock Fast", reasoning: false, thinkingLevels: ["off"], contextWindow: 128_000, maxTokens: 4_000, input: ["text"], available: true },
];
export const TOOLS = [
	{ name: "count", description: "Count from 1 to n, one line at a time", requiresApproval: false },
	{ name: "delete_file", description: "Delete a file", requiresApproval: true },
	{ name: "bash", description: "Run a shell command", requiresApproval: true },
];
const DEFAULTS = { model: { provider: "mock", modelId: "mock-1" }, thinkingLevel: "medium", cwd: "/home/brad/work", tools: TOOLS.map((t) => t.name) };

class Aborted extends Error {}

const sleep = (ms, signal) =>
	new Promise((resolve, reject) => {
		if (signal?.aborted) return reject(new Aborted());
		const timer = setTimeout(resolve, ms);
		signal?.addEventListener("abort", () => {
			clearTimeout(timer);
			reject(new Aborted());
		}, { once: true });
	});

const emptySpend = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, byModel: {}, byTool: {} });
const textBlock = (text) => ({ type: "text", text });

export class LiveConversation {
	watchers = new Set();
	items = [];
	contextStart = null;
	run = null;
	streaming = null;
	tools = new Map(); // callId → slot
	inbox = [];
	approvals = new Map(); // approvalId → { approval, resolve }
	compactions = [];
	stored = {};
	spend = emptySpend();
	archived = false;
	parent = null;
	#byRequestId = new Map();
	#abort = null;

	constructor(host, { id, title, settings, createdAt = Date.now() }) {
		this.host = host;
		this.id = id;
		this.title = title;
		this.createdAt = createdAt;
		this.updatedAt = createdAt;
		if (settings) this.#applySettings(settings);
	}

	get isLive() {
		return true;
	}

	// State (sections 4.10 and 6.1)

	effective() {
		return {
			model: this.stored.model ?? DEFAULTS.model,
			thinkingLevel: this.stored.thinkingLevel ?? DEFAULTS.thinkingLevel,
			cwd: this.stored.cwd ?? DEFAULTS.cwd,
			tools: Array.isArray(this.stored.tools) ? this.stored.tools : DEFAULTS.tools,
		};
	}

	settings() {
		return { stored: { ...this.stored }, effective: this.effective() };
	}

	summary() {
		const status = this.approvals.size > 0 ? "needsApproval" : this.run ? "busy" : "idle";
		const firstUser = this.items.find((item) => item.type === "user");
		const title = this.title ?? firstUser?.content?.[0]?.text?.split("\n")[0].slice(0, 80) ?? "New conversation";
		return {
			id: this.id, title, status, archived: this.archived, parent: this.parent, model: this.effective().model,
			createdAt: this.createdAt, updatedAt: this.updatedAt, pendingApprovals: this.approvals.size, spend: this.spend,
		};
	}

	snapshot(limit) {
		const window = this.items.slice(-limit);
		return {
			type: "snapshot",
			conversation: { id: this.id, title: this.summary().title, archived: this.archived, parent: this.parent },
			items: window,
			hasEarlier: window.length < this.items.length,
			contextStart: this.contextStart,
			run: this.run,
			streaming: this.streaming,
			retry: null,
			tools: [...this.tools.values()].filter((slot) => slot.status === "running"),
			inbox: this.inbox,
			approvals: [...this.approvals.values()].map((a) => a.approval),
			compactions: this.compactions,
			settings: this.settings(),
			spend: this.spend,
		};
	}

	history(before, limit) {
		const older = this.items.filter((item) => item.id < before);
		const page = older.slice(-limit);
		return { items: page, hasEarlier: page.length < older.length };
	}

	/** One frame to every watcher, then a summary update for host watchers. */
	emit(...events) {
		this.updatedAt = Date.now();
		for (const watcher of this.watchers) watcher(events);
		this.host.changed(this);
	}

	#addItem(item) {
		this.items.push(item);
		return { type: "item.added", item };
	}

	// Commands (section 5)

	submit({ requestId, text, whenBusy = "followUp" }) {
		const existing = this.#byRequestId.get(requestId);
		if (existing) return { submission: existing, duplicate: true };
		const id = this.host.nextId();
		if (this.run || this.inbox.some((item) => item.mode !== "write")) {
			if (whenBusy === "reject") throw Object.assign(new Error("Conversation is busy"), { code: "busy" });
			const submission = { id, requestId, type: "input", status: "queued" };
			this.#byRequestId.set(requestId, submission);
			this.inbox.push({ submissionId: id, mode: whenBusy === "steer" ? "steer" : "followUp", requestId, text });
			this.emit({ type: "submission", submission }, { type: "inbox.changed", items: this.inbox });
			if (!this.run) this.#startNextQueued();
			return { submission, duplicate: false };
		}
		const submission = this.#place({ id, requestId, text });
		this.#start([submission]);
		return { submission, duplicate: false };
	}

	async abort() {
		this.#abort?.abort();
		// A waiting approval does not watch the signal; wake it so the run can finish aborted (fixture 16).
		for (const pending of this.approvals.values()) pending.resolve({ decision: "cancelled" });
		const withdrawn = this.inbox.filter((item) => item.mode !== "write");
		if (withdrawn.length > 0) {
			this.inbox = this.inbox.filter((item) => item.mode === "write");
			this.emit(
				...withdrawn.map((item) => ({ type: "submission", submission: this.#settle(item.requestId, { status: "unanswered", reason: "aborted" }) })),
				{ type: "inbox.changed", items: this.inbox },
			);
		}
		while (this.run) await sleep(10);
	}

	configure(changes) {
		this.#applySettings(changes);
		this.emit({ type: "settings.changed", settings: this.settings() });
		return { settings: this.settings() };
	}

	compact(instructions) {
		const taskId = this.host.nextId();
		const status = { taskId, reason: "manual", blocking: false, attempt: 1, retry: null };
		this.compactions.push(status);
		this.emit({ type: "compaction.started", taskId, reason: "manual", blocking: false });
		setTimeout(() => {
			this.compactions = this.compactions.filter((c) => c.taskId !== taskId);
			const kept = this.items.at(-4) ?? this.items.at(0);
			const events = [];
			if (kept) {
				const summary = `## Summary\n${instructions ? `${instructions}\n` : ""}${this.items.length} items so far.`;
				events.push(this.#addItem({
					id: this.host.nextId(), type: "compaction", at: Date.now(), reason: "manual", contextStart: kept.id,
					summary: `The conversation history before this point was compacted into the following summary:\n\n<summary>\n${summary}\n</summary>`,
				}));
				this.contextStart = kept.id;
			}
			this.emit(...events, { type: "compaction.ended", taskId, reason: "manual" });
		}, 600);
		return { taskId };
	}

	reset(handoff) {
		const id = this.host.nextId();
		const item = { id, type: "reset", at: Date.now(), contextStart: id };
		if (handoff) item.handoff = handoff;
		this.contextStart = id;
		this.emit(this.#addItem(item));
		return {};
	}

	answer(approvalId, decision, by) {
		const pending = this.approvals.get(approvalId);
		if (!pending) throw Object.assign(new Error(`No pending approval ${approvalId}`), { code: "not_found" });
		pending.resolve({ decision, by });
		return { approval: { ...pending.approval, decision, by } };
	}

	fork(at, id, title) {
		const fork = new LiveConversation(this.host, { id, title: title ?? `Fork of ${this.summary().title}` });
		fork.items = this.items.filter((item) => item.id <= at);
		fork.stored = { ...this.stored };
		fork.parent = { conversationId: this.id, at };
		return fork;
	}

	#applySettings(changes) {
		for (const key of ["model", "thinkingLevel", "cwd", "tools"]) {
			if (!(key in changes)) continue;
			if (changes[key] === null) delete this.stored[key];
			else this.stored[key] = changes[key];
		}
	}

	// Runs

	#place({ id, requestId, text }) {
		const entryId = this.host.nextId();
		const submission = { id, requestId, type: "input", status: "placed", entryId };
		this.#byRequestId.set(requestId, submission);
		this.emit(this.#addItem({ id: entryId, type: "user", at: Date.now(), content: [textBlock(text)] }), { type: "submission", submission });
		return submission;
	}

	#settle(requestId, fields) {
		const submission = { ...this.#byRequestId.get(requestId), ...fields };
		this.#byRequestId.set(requestId, submission);
		return submission;
	}

	#startNextQueued() {
		const next = this.inbox.find((item) => item.mode !== "write");
		if (!next) return;
		this.inbox = this.inbox.filter((item) => item !== next);
		this.emit({ type: "inbox.changed", items: this.inbox });
		this.#start([this.#place({ id: next.submissionId, requestId: next.requestId, text: next.text })]);
	}

	#start(inputs) {
		this.run = { inputs: inputs.map((s) => s.id) };
		this.emit({ type: "run.started", inputs: this.run.inputs });
		this.#abort = new AbortController();
		void this.#runLoop(inputs, this.#abort.signal);
	}

	async #runLoop(inputs, signal) {
		let texts = inputs.map((s) => this.items.find((item) => item.id === s.entryId)?.content?.[0]?.text ?? "");
		let toolResult;
		try {
			for (let turn = 0; turn < 4; turn++) {
				const plan = this.#plan(texts, toolResult, turn);
				const callId = await this.#generate(plan, signal);
				if (!plan.tool) break;
				toolResult = await this.#runTool(callId, plan.tool, signal);
				// Steers are placed after the tool round and join this run (section 5, submit).
				const steers = this.inbox.filter((item) => item.mode === "steer");
				if (steers.length > 0) {
					this.inbox = this.inbox.filter((item) => item.mode !== "steer");
					const placed = steers.map((item) => this.#place({ id: item.submissionId, requestId: item.requestId, text: item.text }));
					this.emit({ type: "inbox.changed", items: this.inbox });
					inputs = [...inputs, ...placed];
					// Joining steers are not run events; run.ended lists them (fixture 04-steer-during-tools).
					this.run = { inputs: inputs.map((s) => s.id) };
					texts = steers.map((item) => item.text);
				}
			}
			const answer = this.items.at(-1)?.id;
			this.#endRun(inputs, { status: "done", answerId: answer });
		} catch (error) {
			if (!(error instanceof Aborted)) throw error;
			this.#finishAborted(inputs);
		}
	}

	#endRun(inputs, outcome) {
		const run = this.run;
		this.run = null;
		this.streaming = null;
		this.#abort = null;
		this.emit(
			{ type: "run.ended", inputs: run?.inputs ?? [] },
			...inputs.map((s) => ({ type: "submission", submission: this.#settle(s.requestId, outcome) })),
		);
		this.#startNextQueued();
	}

	#finishAborted(inputs) {
		const events = [];
		if (this.streaming) {
			events.push(this.#addItem({
				id: this.host.nextId(), type: "assistant", at: Date.now(), content: this.streaming.content, stopReason: "aborted",
				model: this.effective().model,
			}));
			this.streaming = null;
		}
		for (const [approvalId, { approval }] of this.approvals) {
			const resultId = this.host.nextId();
			const message = `Tool ${approval.toolName} was aborted`;
			events.push({ type: "approval.resolved", approvalId, decision: "cancelled" }, this.#addItem(this.#result(
				{ callId: approval.callId, name: approval.toolName }, resultId,
				{ content: [textBlock(`<harness>\n[error] ${message}\n</harness>`)], isError: true, diagnostics: [{ severity: "error", code: "aborted", message }] },
			)));
		}
		this.approvals.clear();
		for (const slot of this.tools.values()) {
			const resultId = this.host.nextId();
			events.push({ type: "tool.ended", callId: slot.callId, resultId }, this.#addItem(this.#result(slot, resultId, {
				content: [textBlock(slot.output), textBlock(`<harness>\n[error] Tool ${slot.name} was aborted\n</harness>`)],
				isError: true, diagnostics: [{ severity: "error", code: "aborted", message: `Tool ${slot.name} was aborted` }],
			})));
		}
		this.tools.clear();
		if (events.length > 0) this.emit(...events);
		this.#endRun(inputs, { status: "unanswered", reason: "aborted" });
	}

	#plan(texts, toolResult, turn) {
		const text = texts.join(" ");
		const thinking = this.effective().thinkingLevel !== "off" && turn === 0 ? `The user wrote: "${text.slice(0, 120)}". Decide what to do.` : undefined;
		if (toolResult !== undefined) {
			const steer = turn > 0 && texts.length > 0 ? ` You also said: "${text}".` : "";
			return { text: `${toolResult.isError ? `The tool did not run: ${toolResult.summary}.` : `Done. ${toolResult.summary}.`}${steer}` };
		}
		if (/delete|remove/i.test(text)) {
			return { thinking, text: "I'll delete that file. This needs your approval.", tool: { name: "delete_file", args: { path: "/tmp/notes.txt" }, approval: true } };
		}
		if (/count|tool/i.test(text)) {
			return { thinking, text: "Running the counter.", tool: { name: "count", args: { n: 12 }, lines: 12 } };
		}
		if (/long|explain/i.test(text)) {
			return { thinking, text: LONG_ANSWER };
		}
		return { thinking, text: `This is the mock model answering "${text}". It streams a few words at a time, so the transcript can show text arriving.` };
	}

	/** Streams one assistant message and appends it. Returns the tool call ID, if the plan has a tool. */
	async #generate(plan, signal) {
		const model = this.effective().model;
		this.streaming = { attempt: 1, content: [], model };
		this.emit({ type: "stream.started", attempt: 1, content: [], model });
		const blocks = [];
		if (plan.thinking) blocks.push({ type: "thinking", text: plan.thinking, redacted: false });
		blocks.push(textBlock(plan.text));
		for (const block of blocks) {
			const index = this.streaming.content.length;
			this.streaming.content.push({ ...block, text: "" });
			this.emit({ type: "stream.delta", ops: [{ op: "start", index, block: { ...block, text: "" } }] });
			const words = block.text.split(/(?<=\s)/);
			for (let i = 0; i < words.length; i += 3) {
				await sleep(45, signal);
				const chunk = words.slice(i, i + 3).join("");
				this.streaming.content[index].text += chunk;
				this.emit({ type: "stream.delta", ops: [{ op: "appendText", index, text: chunk }] });
			}
		}
		let callId;
		if (plan.tool) {
			callId = `call-${this.host.nextId()}`;
			const index = this.streaming.content.length;
			const block = { type: "toolCall", id: callId, name: plan.tool.name, args: plan.tool.args };
			this.streaming.content.push(block);
			this.emit({ type: "stream.delta", ops: [{ op: "start", index, block }] });
		}
		const words = this.streaming.content.reduce((n, b) => n + (b.text?.split(/\s+/).length ?? 4), 0);
		const usage = { input: 150 + this.items.length * 12, output: Math.round(words * 1.4), cacheRead: 0, cacheWrite: 0 };
		usage.total = usage.input + usage.output;
		usage.cost = usage.input * 3e-6 + usage.output * 15e-6;
		this.#addSpend(`${model.provider}/${model.modelId}`, usage);
		const item = {
			id: this.host.nextId(), type: "assistant", at: Date.now(), content: this.streaming.content,
			stopReason: plan.tool ? "toolUse" : "stop", model, spend: usage,
		};
		this.streaming = null;
		this.emit(this.#addItem(item), { type: "spend.changed", spend: this.spend });
		return callId;
	}

	async #runTool(callId, tool, signal) {
		if (tool.approval) {
			const approvalId = `${this.id}:${callId}`;
			const approval = { approvalId, conversationId: this.id, callId, toolName: tool.name, args: tool.args, requestedAt: Date.now() };
			const answer = await new Promise((resolve) => {
				this.approvals.set(approvalId, { approval, resolve });
				this.emit({ type: "approval.requested", approval });
			});
			if (answer.decision === "cancelled") throw new Aborted();
			this.approvals.delete(approvalId);
			this.emit({ type: "approval.resolved", approvalId, decision: answer.decision, by: answer.by });
			if (answer.decision === "deny") {
				const resultId = this.host.nextId();
				const message = `Tool call blocked: Denied by ${answer.by ?? "the user"}`;
				this.emit({ type: "tool.ended", callId }, this.#addItem(this.#result({ callId, name: tool.name }, resultId, {
					content: [textBlock(`<harness>\n[error] ${message}\n</harness>`)], isError: true,
					diagnostics: [{ severity: "error", code: "blocked", message }],
				})));
				return { isError: true, summary: "you denied it" };
			}
		}
		const slot = { callId, name: tool.name, status: "running", output: "", droppedBytes: 0, droppedLines: 0, details: null, diagnostics: [] };
		this.tools.set(callId, slot);
		this.emit({ type: "tool.started", callId, name: tool.name, args: tool.args });
		const lines = tool.lines ?? 1;
		for (let i = 1; i <= lines; i++) {
			await sleep(tool.lines ? 150 : 50, signal);
			const chunk = tool.lines ? `${i}\n` : `removed ${tool.args.path}\n`;
			slot.output += chunk;
			this.emit({ type: "tool.updated", callId, output: i === 1 ? { set: chunk } : { append: chunk } });
		}
		this.tools.delete(callId);
		const resultId = this.host.nextId();
		this.emit({ type: "tool.ended", callId, resultId }, this.#addItem(this.#result(slot, resultId, {
			content: [textBlock(slot.output)], isError: false, diagnostics: [], details: tool.lines ? { counted: lines } : undefined,
		})));
		return { isError: false, summary: tool.lines ? `Counted to ${lines}` : `Deleted ${tool.args.path}` };
	}

	#result(slot, id, fields) {
		const item = { id, type: "toolResult", at: Date.now(), callId: slot.callId, toolName: slot.name, durationMs: 120, ...fields };
		if (item.details === undefined) delete item.details;
		return item;
	}

	#addSpend(key, usage) {
		const add = (target) => {
			for (const field of ["input", "output", "cacheRead", "cacheWrite", "total", "cost"]) target[field] = (target[field] ?? 0) + usage[field];
		};
		this.spend = structuredClone(this.spend);
		this.spend.byModel[key] ??= {};
		add(this.spend.byModel[key]);
		add(this.spend);
	}
}

const LONG_ANSWER = [
	"Here is a longer answer, so the transcript has paragraphs to lay out.",
	"The server keeps every conversation in its own SQLite store. Each commit is durable before anything is shown, so a crash loses at most the last partial answer.",
	"When a client falls behind, the server sends a fresh snapshot instead of replaying what it missed. The app replaces its state and carries on.",
	"Steers join the running work after the current tool round. Follow-ups wait for the run to finish and then start the next one.",
	"Approvals are built by the server from a beforeTool hook. While a call waits, the conversation shows as needing approval in the sidebar.",
].join("\n\n");

/** A conversation with `turns` question-and-answer pairs, every fifth with a tool call, for scrolling tests. */
export function longTranscript(host, id, turns) {
	const conversation = new LiveConversation(host, { id, title: `Long transcript (${turns * 2}+ items)`, createdAt: Date.now() - 86_400_000 });
	let seed = 7;
	const random = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
	const words = "agent server snapshot reducer conversation durable commit transcript stream tool output approval steer follow-up model context compaction spend inbox socket".split(" ");
	const sentence = (n) => Array.from({ length: n }, () => words[Math.floor(random() * words.length)]).join(" ");
	for (let turn = 0; turn < turns; turn++) {
		conversation.items.push({ id: host.nextId(), type: "user", content: [textBlock(`Question ${turn + 1}: ${sentence(4 + Math.floor(random() * 12))}?`)] });
		const paragraphs = Array.from({ length: 1 + Math.floor(random() * 3) }, () => `${sentence(10 + Math.floor(random() * 40))}.`);
		const content = [textBlock(paragraphs.join("\n\n"))];
		if (turn % 5 === 4) {
			const callId = `call-long-${turn}`;
			content.push({ type: "toolCall", id: callId, name: "count", args: { n: 3 } });
			conversation.items.push({ id: host.nextId(), type: "assistant", content, stopReason: "toolUse", model: DEFAULTS.model });
			conversation.items.push({ id: host.nextId(), type: "toolResult", callId, toolName: "count", content: [textBlock("1\n2\n3\n")], isError: false, diagnostics: [] });
			conversation.items.push({ id: host.nextId(), type: "assistant", content: [textBlock("Counted to three.")], stopReason: "stop", model: DEFAULTS.model });
		} else {
			conversation.items.push({ id: host.nextId(), type: "assistant", content, stopReason: "stop", model: DEFAULTS.model });
		}
	}
	return conversation;
}
