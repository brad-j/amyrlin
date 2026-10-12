// The Harness and everything the protocol needs from it beyond watchEvents(): conversation metadata, summaries for
// host.watch, approvals, and the commands of docs/protocol.md section 5.
import { randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import {
	AgentDoc,
	ConversationBusy,
	createRegistry,
	defineDoc,
	defineExtension,
	Harness,
	hook,
	InboxDoc,
	LiveDoc,
	section,
	ToolTask,
	UsageDoc,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { readApiKey } from "./config.mjs";
import { entryItem, text, usage } from "./translate.mjs";

export const context = BACKGROUND_CONTEXT;

/** Server-owned conversation metadata: pi-durable has no titles or archiving (protocol section 4.10). */
export const MetaDoc = defineDoc({
	kind: "amyrlin.meta",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({}),
});

/** The host's stable identity (protocol section 3, `hostId`). */
const HostDoc = defineDoc({ kind: "amyrlin.host", version: 1, scope: "session", initial: () => ({}) });

export class ProtocolError extends Error {
	constructor(code, message, { retryable = false, data } = {}) {
		super(message);
		this.code = code;
		this.retryable = retryable;
		this.data = data;
	}
}

const SPEND_FIELDS = ["input", "output", "cacheRead", "cacheWrite", "total", "cost"];

/** UsageState → protocol Spend (section 4.2). */
export function spendOf(state) {
	const out = { byModel: {}, byTool: {} };
	for (const field of SPEND_FIELDS) out[field] = 0;
	for (const [bucket, key] of [["models", "byModel"], ["tools", "byTool"]]) {
		for (const [name, u] of Object.entries(state?.[bucket] ?? {})) {
			out[key][name] = usage(u);
			for (const field of SPEND_FIELDS) out[field] += out[key][name][field];
		}
	}
	return out;
}

/** Approvals built on a beforeTool hook (protocol section 8). Pending ones live in memory. */
class Approvals {
	pending = new Map(); // approvalId → { approval, resolve }
	resolved = new Map(); // approvalId → resolution, kept so a repeated answer gets the same result
	listeners = new Set(); // (conversationId, event) => void

	forConversation(conversationId) {
		return [...this.pending.values()].map((p) => p.approval).filter((a) => a.conversationId === conversationId);
	}

	count(conversationId) {
		return this.forConversation(conversationId).length;
	}

	/** Waits for an answer. A rerun after a restart raises the same approvalId again (fixture 15). */
	wait(approval, signal) {
		return new Promise((resolve) => {
			if (signal?.aborted) return resolve({ decision: "cancelled" });
			this.resolved.delete(approval.approvalId);
			this.pending.set(approval.approvalId, { approval, resolve });
			this.#emit(approval.conversationId, { type: "approval.requested", approval });
			// conversation.abort() fires this signal at once (fixture 16).
			signal?.addEventListener("abort", () => this.#settle(approval.approvalId, { decision: "cancelled" }), { once: true });
		});
	}

	answer(approvalId, decision, by, message) {
		const pending = this.pending.get(approvalId);
		if (pending === undefined) {
			const previous = this.resolved.get(approvalId);
			if (previous?.decision === decision) return previous;
			throw new ProtocolError(previous ? "already_resolved" : "not_found", previous ? `Approval ${approvalId} was already ${previous.decision}` : `No pending approval ${approvalId}`, { data: previous });
		}
		return this.#settle(approvalId, { decision, by, message });
	}

	#settle(approvalId, outcome) {
		const pending = this.pending.get(approvalId);
		if (pending === undefined) return this.resolved.get(approvalId);
		this.pending.delete(approvalId);
		const resolution = { ...pending.approval, ...outcome };
		this.resolved.set(approvalId, resolution);
		pending.resolve(outcome);
		const event = { type: "approval.resolved", approvalId, decision: outcome.decision };
		if (outcome.by !== undefined) event.by = outcome.by;
		if (outcome.message !== undefined) event.message = outcome.message;
		this.#emit(pending.approval.conversationId, event);
		return resolution;
	}

	#emit(conversationId, event) {
		for (const listener of this.listeners) listener(conversationId, event);
	}
}

export class Host {
	/** @param {import("./config.mjs").Config} config */
	constructor(config, log = console.log) {
		this.config = config;
		this.log = log;
		this.approvals = new Approvals();
		this.summaries = new Map(); // conversationId → ConversationSummary
		this.summaryListeners = new Set(); // (summary) => void
		this.spendListeners = new Set(); // (spend) => void
		this.stuck = new Map(); // conversationId → { reason, taskKind }
		this.#byRequestId = new Map(); // conversations.create/fork requestId → conversationId
		this.#dirty = new Set();
	}

	#byRequestId;
	#dirty;
	#flushTimer;

	async open() {
		const { models, model } = this.#models();
		this.models = models;
		this.registry = createRegistry();
		this.registry.install(CodingTools);
		this.registry.install(this.#extension());
		mkdirSync(dirname(this.config.store), { recursive: true });
		const storage = await openNodeSqliteStorage(this.config.store);
		const shellEnv = { ...process.env };
		delete shellEnv.ANTHROPIC_API_KEY;
		this.harness = await Harness.open(
			storage,
			{
				models: this.#workingWindow(models),
				registry: this.registry,
				settings: { toolExecution: "parallel", compaction: { enabled: true } },
				env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? this.config.cwd, shellEnv }),
				onReport: (error) => this.log("report:", error?.message ?? error),
			},
			context,
		);
		this.defaultModel = model;
		this.hostId = await this.harness.commit(async (tx) => {
			const doc = await tx.doc(HostDoc);
			doc.hostId ??= randomUUID();
			return doc.hostId;
		}, context);
		// Settle work the last process left unfinished before anyone can watch (protocol section 9.3).
		this.harness.resume();
		this.harness.subscribeCommits((publication) => this.#onCommit(publication));
		for (const id of await this.#conversationIds()) {
			const meta = await this.harness.snapshot(MetaDoc, id, context);
			if (meta?.requestId !== undefined) this.#byRequestId.set(meta.requestId, id);
			await this.#refreshSummary(id);
		}
		await this.refreshStuck();
		this.#stuckTimer = setInterval(() => void this.refreshStuck().catch(() => {}), 60_000);
		this.approvals.listeners.add((conversationId) => this.#markDirty(conversationId));
		// A close this process didn't ask for is a storage failure (pi-durable "Errors", rule 1). Exit, and systemd
		// restarts the service, which reopens the store (protocol section 9.4).
		this.harness.subscribeClose(() => {
			if (this.#closing) return;
			this.log("the harness closed after a storage failure; exiting");
			setImmediate(() => process.exit(1));
		});
	}

	#stuckTimer;

	#closing = false;

	async close() {
		this.#closing = true;
		clearInterval(this.#stuckTimer);
		clearTimeout(this.#flushTimer);
		await this.harness?.close(context);
	}

	identity() {
		return { hostId: this.hostId, name: this.config.name, serverVersion: "0.1.0", durableVersion: "1.1.0" };
	}

	// Models

	#models() {
		if (this.config.provider === "faux") return fauxModels();
		// The key comes from its file when a request needs it, not from this process's environment (as in gaidin).
		const models = createModels({
			authContext: {
				env: async (name) => (name === "ANTHROPIC_API_KEY" ? readApiKey(this.config) : undefined),
				fileExists: async () => false,
			},
		});
		models.setProvider(anthropicProvider());
		return { models, model: this.config.model };
	}

	/**
	 * Compaction times itself from the model's context window. Anthropic charges more for requests over 200,000 input
	 * tokens on some models, and long contexts are slow and costly anyway, so `compactionWindowTokens` lets the host
	 * compact earlier. Only compaction reads the window; requests are unchanged.
	 */
	#workingWindow(models) {
		const tokens = this.config.compactionWindowTokens;
		if (tokens === undefined) return models;
		return new Proxy(models, {
			get(target, key) {
				if (key === "getModel") {
					return (provider, id) => {
						const model = target.getModel(provider, id);
						return model === undefined ? undefined : { ...model, contextWindow: Math.min(model.contextWindow, tokens) };
					};
				}
				const value = Reflect.get(target, key);
				return typeof value === "function" ? value.bind(target) : value;
			},
		});
	}

	modelInfo() {
		const all = this.models.getModels(this.defaultModel.provider);
		const offered = this.config.models === undefined ? all : all.filter((m) => this.config.models.includes(m.id));
		return offered.map((m) => ({
			provider: m.provider,
			modelId: m.id,
			name: m.name,
			reasoning: m.reasoning,
			thinkingLevels: m.reasoning ? Object.keys(m.thinkingLevelMap ?? { off: 1, low: 1, medium: 1, high: 1 }) : ["off"],
			contextWindow: m.contextWindow,
			maxTokens: m.maxTokens,
			input: m.input,
			available: true,
		}));
	}

	toolInfo() {
		return this.registry.snapshot().tools().map(({ tool }) => ({
			name: tool.name,
			description: tool.description,
			requiresApproval: this.config.requireApproval.includes(tool.name),
		}));
	}

	// The amyrlin extension: the system prompt and the approval hook.

	#extension() {
		const approvals = this.approvals;
		const requireApproval = new Set(this.config.requireApproval);
		return defineExtension({
			name: "amyrlin",
			sections: [
				section("preamble", () => this.config.instructions, { tag: false }),
				section("cwd", (input) => input.env?.cwd),
			],
			hooks: [
				hook(ToolTask, {
					beforeTool: async (call, api, hookContext) => {
						if (!requireApproval.has(call.name)) return undefined;
						const approval = {
							approvalId: `${api.conversationId}:${call.id}`,
							conversationId: api.conversationId,
							callId: call.id,
							toolName: call.name,
							args: call.arguments ?? {},
							requestedAt: Date.now(),
						};
						const outcome = await approvals.wait(approval, hookContext.abortSignal);
						if (outcome.decision === "approve") return undefined;
						if (outcome.decision === "deny") {
							return { block: `Denied by ${outcome.by ?? "the user"}${outcome.message ? `: ${outcome.message}` : ""}` };
						}
						return { block: "The approval was cancelled" };
					},
				}),
			],
		});
	}

	// Conversations

	async conversation(id) {
		const conversation = typeof id === "number" ? await this.harness.conversation(id, context) : undefined;
		if (conversation === undefined) throw new ProtocolError("not_found", `No conversation ${id}`);
		return conversation;
	}

	/** Ownerless conversations; subagents owned by tasks are not listed in v1. */
	async #conversationIds() {
		const ids = [];
		let cursor;
		do {
			const page = await this.harness.commit((tx) => tx.scanConversations({ order: "ascending" }, 200, cursor), context);
			for (const record of page.items) if (record.owner === undefined) ids.push(record.id);
			cursor = page.next;
		} while (cursor !== undefined);
		return ids;
	}

	async create({ requestId, title, settings }) {
		return this.#dedupe(requestId, async () => {
			// pi-durable has no host-wide default model: a conversation without one settles every input `no_model`.
			const agent = await this.#agentChange({ model: this.defaultModel, thinkingLevel: this.config.thinkingLevel, ...settings });
			const conversation = await this.harness.createConversation(
				{ ownership: { kind: "ownerless" }, agent, init: this.#initMeta({ requestId, title }) },
				context,
			);
			return conversation.id;
		});
	}

	async fork({ requestId, conversationId, at, title }) {
		return this.#dedupe(requestId, async () => {
			const source = await this.conversation(conversationId);
			try {
				const fork = await source.fork(at, { ownership: { kind: "ownerless" }, init: this.#initMeta({ requestId, title }) }, context);
				return fork.id;
			} catch (error) {
				throw new ProtocolError("not_found", `Entry ${at} is not visible in conversation ${conversationId}: ${error.message}`);
			}
		});
	}

	#initMeta({ requestId, title }) {
		return async (tx, id) => {
			const meta = await tx.doc(MetaDoc, id);
			meta.createdAt = Date.now();
			if (requestId !== undefined) meta.requestId = requestId;
			if (typeof title === "string" && title.trim() !== "") meta.title = title.trim();
		};
	}

	async #dedupe(requestId, make) {
		if (typeof requestId !== "string") throw new ProtocolError("bad_request", "requestId is required");
		const existing = this.#byRequestId.get(requestId);
		if (existing !== undefined) return { conversation: await this.summary(existing), duplicate: true };
		const id = await make();
		this.#byRequestId.set(requestId, id);
		return { conversation: await this.#refreshSummary(id), duplicate: false };
	}

	async archive({ conversationId, archived }) {
		await this.conversation(conversationId);
		await this.harness.commit(async (tx) => {
			(await tx.doc(MetaDoc, conversationId)).archived = Boolean(archived);
		}, context);
		return { conversation: await this.#refreshSummary(conversationId) };
	}

	// Commands on one conversation

	async submit({ conversationId, requestId, text: content, whenBusy = "followUp" }) {
		if (typeof requestId !== "string" || typeof content !== "string") throw new ProtocolError("bad_request", "submit needs requestId and text");
		if (!["followUp", "steer", "reject"].includes(whenBusy)) throw new ProtocolError("bad_request", `whenBusy ${whenBusy}`);
		const conversation = await this.conversation(conversationId);
		const before = await this.harness.commit((tx) => tx.submissionByRequest(conversationId, requestId), context);
		let submission;
		try {
			submission = await conversation.submit({ type: "input", content, requestId, whenBusy }, context);
		} catch (error) {
			if (error instanceof ConversationBusy) throw new ProtocolError("busy", "The conversation is busy");
			throw error;
		}
		return { submission: wireSubmission(await submission.status(context)), duplicate: before !== undefined };
	}

	async abort({ conversationId }) {
		await (await this.conversation(conversationId)).abort(context);
		return {};
	}

	async configure({ conversationId, changes }) {
		const conversation = await this.conversation(conversationId);
		await conversation.configure(await this.#agentChange(changes ?? {}), context);
		return { settings: await this.settings(conversationId) };
	}

	/** Protocol settings changes → a pi-durable AgentChange. */
	async #agentChange(changes) {
		const change = {};
		if ("model" in changes) {
			const model = changes.model;
			if (model === null) throw new ProtocolError("invalid_settings", "A conversation needs a model; pick one instead of clearing it");
			if (this.models.getModel(model?.provider, model?.modelId) === undefined) {
				throw new ProtocolError("invalid_settings", `Unknown model ${model?.provider}/${model?.modelId}`);
			}
			change.model = model;
		}
		if ("thinkingLevel" in changes) {
			const level = changes.thinkingLevel;
			if (level !== null && !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(level)) {
				throw new ProtocolError("invalid_settings", `Unknown thinking level ${level}`);
			}
			change.thinkingLevel = level;
		}
		if ("cwd" in changes) change.cwd = changes.cwd;
		if ("tools" in changes) {
			if (changes.tools === null) change.tools = null;
			else {
				const installed = new Map(this.registry.snapshot().tools().map(({ tool }) => [tool.name, tool]));
				const unknown = changes.tools.filter((name) => !installed.has(name));
				if (unknown.length > 0) throw new ProtocolError("invalid_settings", `Unknown tools ${unknown.join(", ")}`);
				change.tools = changes.tools.map((name) => installed.get(name));
			}
		}
		return change;
	}

	/** Stored and resolved settings (protocol section 4.8). */
	async settings(conversationId) {
		const stored = (await this.harness.snapshot(AgentDoc, conversationId, context)) ?? {};
		const agent = await (await this.conversation(conversationId)).agent(context);
		return settingsFrom(stored, this.effective(agent));
	}

	effective(agent) {
		return {
			model: agent.model ?? null,
			thinkingLevel: agent.thinkingLevel,
			cwd: agent.cwd ?? this.config.cwd,
			tools: agent.tools.map((tool) => tool.name),
		};
	}

	async compact({ conversationId, instructions }) {
		const taskId = await (await this.conversation(conversationId)).compact(instructions ?? undefined, context);
		return { taskId };
	}

	async reset({ conversationId, handoff }) {
		await (await this.conversation(conversationId)).reset(handoff ?? undefined, context);
		return {};
	}

	answerApproval({ approvalId, decision, message }, login) {
		if (!["approve", "deny"].includes(decision)) throw new ProtocolError("bad_request", `decision ${decision}`);
		return { approval: this.approvals.answer(String(approvalId), decision, login, message ?? undefined) };
	}

	/** Items before `before`, oldest first (protocol section 5, conversation.history). */
	async history({ conversationId, before, limit = 100 }) {
		const conversation = await this.conversation(conversationId);
		return this.itemsBefore(conversation, before, Math.min(Math.max(1, limit), 500));
	}

	async itemsBefore(conversation, before, limit) {
		const items = [];
		let cursor;
		let more = false;
		do {
			const page = await conversation.entries({ maxEntryId: before - 1, order: "descending" }, limit, cursor, context);
			for (const entry of page.items) {
				const item = entryItem(entry);
				if (item !== undefined && items.length < limit) items.push(item);
				else if (item !== undefined) more = true;
			}
			cursor = page.next;
		} while (cursor !== undefined && items.length < limit);
		return { items: items.reverse(), hasEarlier: more || cursor !== undefined };
	}

	// Summaries (protocol sections 4.10 and 6.2)

	async summary(id) {
		return this.summaries.get(id) ?? (await this.#refreshSummary(id));
	}

	listSummaries(includeArchived = true) {
		return [...this.summaries.values()].filter((s) => includeArchived || !s.archived).sort((a, b) => b.updatedAt - a.updatedAt);
	}

	async hostSpend() {
		return spendOf(await this.harness.usage(context));
	}

	#onCommit(publication) {
		for (const change of publication.changes) {
			const id =
				change.type === "document" || change.type === "document.copy"
					? change.conversationId
					: change.type === "conversation"
						? change.value?.id
						: change.value?.conversationId;
			if (typeof id === "number") this.#markDirty(id);
		}
	}

	/** Coalesces summary updates to at most four per second (protocol section 6.2). */
	#markDirty(id) {
		this.#dirty.add(id);
		this.#flushTimer ??= setTimeout(() => void this.#flush(), 250);
	}

	async #flush() {
		this.#flushTimer = undefined;
		const ids = [...this.#dirty];
		this.#dirty.clear();
		let spendChanged = false;
		for (const id of ids) {
			const before = this.summaries.get(id);
			const after = await this.#refreshSummary(id).catch((error) => this.log(`summary ${id}:`, error.message));
			if (after === undefined) continue;
			if (JSON.stringify(before) === JSON.stringify(after)) continue;
			if (JSON.stringify(before?.spend) !== JSON.stringify(after.spend)) spendChanged = true;
			for (const listener of this.summaryListeners) listener(after);
		}
		if (spendChanged && this.spendListeners.size > 0) {
			const spend = await this.hostSpend();
			for (const listener of this.spendListeners) listener(spend);
		}
	}

	async #refreshSummary(id) {
		const conversation = await this.harness.conversation(id, context);
		if (conversation === undefined) return undefined;
		const record = await this.harness.commit((tx) => tx.conversation(id), context);
		const [meta, live, usageState, agent] = await Promise.all([
			this.harness.snapshot(MetaDoc, id, context),
			this.harness.snapshot(LiveDoc, id, context),
			this.harness.snapshot(UsageDoc, id, context),
			this.harness.snapshot(AgentDoc, id, context),
		]);
		const newest = (await conversation.entries({}, 1, undefined, context)).items[0];
		const pendingApprovals = this.approvals.count(id);
		const stuck = this.stuck.get(id);
		const createdAt = meta?.createdAt ?? newest?.model?.[0]?.timestamp ?? 0;
		const summary = {
			id,
			title: meta?.title ?? (await this.#firstUserLine(conversation)) ?? "New conversation",
			status: pendingApprovals > 0 ? "needsApproval" : stuck ? "stuck" : live?.run ? "busy" : "idle",
			archived: meta?.archived === true,
			parent: record?.parent ?? null,
			model: agent?.model ?? null,
			createdAt,
			updatedAt: newest?.model?.[0]?.timestamp ?? createdAt,
			pendingApprovals,
			spend: spendOf(usageState),
		};
		if (stuck) summary.stuck = stuck;
		this.summaries.set(id, summary);
		return summary;
	}

	async #firstUserLine(conversation) {
		const page = await conversation.entries({ order: "ascending" }, 20, undefined, context);
		const user = page.items.find((entry) => entry.model?.[0]?.role === "user" && entry.kind !== "pi.reset" && entry.kind !== "pi.compaction");
		const line = text(user?.model?.[0]?.content).split("\n")[0].trim();
		return line === "" ? undefined : line.slice(0, 80);
	}

	/** Conversations with a task no installed definition can run (protocol section 4.10, `stuck`). */
	async refreshStuck() {
		const inspection = await this.harness.inspect(context);
		const next = new Map();
		for (const task of inspection.tasks) {
			if (task.state.kind === "blocked") next.set(task.record.conversationId, { reason: task.state.reason, taskKind: task.record.kind });
		}
		const changed = new Set([...this.stuck.keys(), ...next.keys()]);
		this.stuck = next;
		for (const id of changed) this.#markDirty(id);
	}

	/** `text` and `kind` of queued inbox items, for inbox enrichment (protocol section 4.6). */
	async inboxExtras(conversationId) {
		const inbox = await this.harness.snapshot(InboxDoc, conversationId, context);
		const extras = new Map();
		for (const item of inbox?.items ?? []) {
			if (item.mode === "write") extras.set(item.id, { kind: item.entry?.kind });
			else extras.set(item.id, { text: text(item.content) });
		}
		return extras;
	}
}

export function settingsFrom(stored, effective) {
	const out = {};
	for (const key of ["model", "thinkingLevel", "cwd", "tools", "instructions"]) if (stored[key] !== undefined) out[key] = stored[key];
	return { stored: out, effective };
}

function wireSubmission(record) {
	const s = { id: record.id, type: record.type, status: record.status };
	if (record.requestId !== undefined) s.requestId = record.requestId;
	if (record.entry !== undefined) s.entryId = record.entry;
	if (record.answer !== undefined) s.answerId = record.answer;
	if (record.reason !== undefined) s.reason = record.reason;
	if (record.detail !== undefined) s.detail = record.detail;
	return s;
}

/**
 * For development without a key: a scripted model. "bash" in a message calls `bash` (which needs approval by default),
 * "read" calls `read`; anything else gets a short streamed answer.
 */
function fauxModels() {
	const models = createModels();
	const faux = fauxProvider({ tokensPerSecond: 60, tokenSize: { min: 1, max: 3 }, models: [{ id: "faux-1", reasoning: true, contextWindow: 200_000, maxTokens: 8_000 }] });
	const step = (transcript) => {
		const last = transcript.messages.at(-1);
		if (last?.role === "toolResult") {
			return fauxAssistantMessage(fauxText(`The ${last.toolName} call ${last.isError ? "failed" : "returned"}: ${text(last.content).slice(0, 200)}`));
		}
		const asked = text(transcript.messages.findLast((m) => m.role === "user")?.content);
		if (/\bbash\b/i.test(asked)) return fauxAssistantMessage([fauxText("Running a command."), fauxToolCall("bash", { command: "echo hello from $(hostname) && sleep 1 && date" })], { stopReason: "toolUse" });
		if (/\bread\b/i.test(asked)) return fauxAssistantMessage([fauxToolCall("read", { path: "README.md" })], { stopReason: "toolUse" });
		return fauxAssistantMessage(fauxText(`This is the faux model on the real amyrlin server. You said: "${asked}". Ask for bash or read to see a tool call.`));
	};
	faux.setResponses(Array.from({ length: 10_000 }, () => step));
	models.setProvider(faux.provider);
	return { models, model: { provider: "faux", modelId: "faux-1" } };
}
