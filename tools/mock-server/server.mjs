// Mock amyrlin server: speaks protocol v1 (docs/protocol.md) on ws://127.0.0.1:8787/amyrlin.
// Every fixture in fixtures/durable-1.1.0 is a read-only conversation that replays with its recorded timing each time
// it is watched. "Live chat" and new conversations answer with a scripted model (live.mjs).
//   PORT=8787  REPLAY_SPEED=1  node server.mjs
//   curl -X POST http://127.0.0.1:8787/debug/drop   breaks every connection, to test reconnects.
import { readdirSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { hostname } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { LiveConversation, longTranscript, MODELS, TOOLS } from "./live.mjs";
import { translateFixture } from "../../server/src/translate.mjs";
import { acceptUpgrade } from "../../server/src/ws.mjs";

const PORT = Number(process.env.PORT ?? 8787);
const REPLAY_SPEED = Number(process.env.REPLAY_SPEED ?? 1);
const LIMITS = { maxFrameBytes: 16 * 1024 * 1024, snapshotItems: 200 };
const HOST = { hostId: process.env.HOST_ID ?? "7d0c1d52-6f0a-4c39-9a51-mock00000001", name: `mock on ${hostname().split(".")[0]}`, serverVersion: "mock-0.1.0", durableVersion: "1.1.0 (fixtures)" };
const fixtures = fileURLToPath(new URL("../../fixtures/durable-1.1.0/", import.meta.url));

const log = (...parts) => console.log(new Date().toISOString().slice(11, 23), ...parts);

class Failure extends Error {
	constructor(code, message, retryable = false) {
		super(message);
		this.code = code;
		this.retryable = retryable;
	}
}

/** A fixture conversation: each watch replays its frames from the first snapshot, on the recorded clock. */
class ReplayConversation {
	isLive = false;
	archived = false;
	watchers = new Set();

	constructor(id, name, createdAt) {
		this.id = id;
		this.name = name;
		this.createdAt = createdAt;
		this.frames = translateFixture(readFileSync(join(fixtures, `${name}.jsonl`), "utf8"), { conversationId: id, title: this.title });
		const lastSpend = this.frames.flatMap((f) => f.events).filter((e) => e.type === "spend.changed" || e.type === "snapshot").at(-1)?.spend;
		this.spend = lastSpend ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, byModel: {}, byTool: {} };
	}

	get title() {
		return `Replay ${this.name.replace(/^(\d\d)-/, "$1 ").replaceAll("-", " ")}`;
	}

	summary() {
		return {
			id: this.id, title: this.title, status: "idle", archived: this.archived, parent: null,
			model: { provider: "faux", modelId: "faux-1" }, createdAt: this.createdAt, updatedAt: this.createdAt, pendingApprovals: 0, spend: this.spend,
		};
	}

	/** Schedules every frame for one subscriber and returns a cancel function. */
	replay(send) {
		const start = this.frames[0]?.t ?? 0;
		const timers = this.frames.map((frame) => setTimeout(() => send(frame.events), (frame.t - start) / REPLAY_SPEED));
		return () => timers.forEach(clearTimeout);
	}
}

class MockHost {
	conversations = new Map();
	hostWatchers = new Set();
	#nextId = 1000;
	#byRequestId = new Map();

	constructor() {
		const now = Date.now();
		this.add(new LiveConversation(this, { id: this.nextId(), title: "Live chat", createdAt: now }));
		this.add(longTranscript(this, this.nextId(), 1000));
		const names = readdirSync(fixtures).filter((f) => f.endsWith(".jsonl")).map((f) => f.slice(0, -6)).sort();
		names.forEach((name, index) => this.add(new ReplayConversation(this.nextId(), name, now - 3_600_000 - index * 60_000)));
	}

	nextId() {
		return this.#nextId++;
	}

	add(conversation) {
		this.conversations.set(conversation.id, conversation);
		this.changed(conversation);
	}

	conversation(id, { live = false } = {}) {
		const conversation = this.conversations.get(id);
		if (!conversation) throw new Failure("not_found", `No conversation ${id}`);
		if (live && !conversation.isLive) throw new Failure("bad_request", "Fixture replays are read-only in the mock");
		return conversation;
	}

	changed(conversation) {
		for (const watcher of this.hostWatchers) watcher([{ type: "conversation.updated", conversation: conversation.summary() }]);
		const spend = this.spend();
		for (const watcher of this.hostWatchers) watcher([{ type: "host.spend", spend }]);
	}

	spend() {
		const total = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, byModel: {}, byTool: {} };
		for (const conversation of this.conversations.values()) {
			if (!conversation.isLive) continue;
			for (const field of ["input", "output", "cacheRead", "cacheWrite", "total", "cost"]) total[field] += conversation.spend[field];
			for (const [key, spend] of Object.entries(conversation.spend.byModel)) {
				total.byModel[key] ??= { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0 };
				for (const field of Object.keys(total.byModel[key])) total.byModel[key][field] += spend[field] ?? 0;
			}
		}
		return total;
	}

	/** Deduplicated creation (section 5, conversations.create and conversations.fork). */
	create(requestId, make) {
		const existing = this.#byRequestId.get(requestId);
		if (existing) return { conversation: existing.summary(), duplicate: true };
		const conversation = make(this.nextId());
		this.#byRequestId.set(requestId, conversation);
		this.add(conversation);
		return { conversation: conversation.summary(), duplicate: false };
	}
}

const host = new MockHost();

// One connection (sections 2 and 3).

function serve(ws, you) {
	let welcomed = false;
	let nextSubscription = 1;
	const subscriptions = new Map(); // id → cancel
	const send = (frame) => ws.send(JSON.stringify(frame));

	ws.on("message", async (text) => {
		let frame;
		try {
			frame = JSON.parse(text);
		} catch {
			return ws.close(4400, "malformed frame");
		}
		if (!welcomed) {
			if (frame.type !== "hello") return ws.close(4400, "expected hello");
			if (!frame.protocols?.includes(1)) {
				send({ type: "goodbye", reason: "unsupported_protocol", protocols: [1] });
				return ws.close(4406, "unsupported protocol");
			}
			welcomed = true;
			log(`hello from ${frame.client?.name ?? "?"} ${frame.client?.version ?? ""} as ${you.login}`);
			return send({ type: "welcome", protocol: 1, host: HOST, you, limits: LIMITS });
		}
		if (frame.type !== "request") return;
		const respond = (result) => send({ type: "response", id: frame.id, result });
		try {
			switch (frame.method) {
				case "conversation.watch":
				case "host.watch": {
					const id = `s${nextSubscription++}`;
					let seq = 0;
					const deliver = (events) => {
						if (subscriptions.has(id)) send({ type: "event", subscription: id, seq: seq++, events });
					};
					if (frame.method === "host.watch") {
						respond({ subscription: id });
						subscriptions.set(id, () => host.hostWatchers.delete(deliver));
						deliver([{ type: "host.snapshot", host: HOST, spend: host.spend(), conversations: [...host.conversations.values()].map((c) => c.summary()) }]);
						host.hostWatchers.add(deliver);
					} else {
						const conversation = host.conversation(frame.params?.conversationId);
						respond({ subscription: id });
						if (conversation.isLive) {
							subscriptions.set(id, () => conversation.watchers.delete(deliver));
							deliver([conversation.snapshot(LIMITS.snapshotItems)]);
							conversation.watchers.add(deliver);
						} else {
							// Frames fire from timers, after the subscription is registered.
							subscriptions.set(id, conversation.replay(deliver));
						}
					}
					return;
				}
				default:
					return respond(await handle(frame.method, frame.params ?? {}, you));
			}
		} catch (error) {
			const failure = error instanceof Failure ? error : new Failure(error.code ?? "internal", error.message);
			if (!(error instanceof Failure) && error.code === undefined) log("internal error", error);
			send({ type: "response", id: frame.id, error: { code: failure.code, message: failure.message, retryable: failure.retryable } });
		}
	});

	ws.on("close", ({ code }) => {
		for (const cancel of subscriptions.values()) cancel();
		subscriptions.clear();
		log(`connection closed (${code})`);
	});

	// Commands (section 5).
	async function handle(method, p, you) {
		switch (method) {
			case "host.info":
				return { host: HOST, models: MODELS, tools: TOOLS, defaults: { model: { provider: "mock", modelId: "mock-1" }, thinkingLevel: "medium" } };
			case "conversations.list":
				return { conversations: [...host.conversations.values()].filter((c) => p.includeArchived || !c.archived).map((c) => c.summary()).sort((a, b) => b.updatedAt - a.updatedAt) };
			case "conversations.create":
				return host.create(p.requestId, (id) => new LiveConversation(host, { id, title: p.title, settings: p.settings }));
			case "conversations.fork":
				return host.create(p.requestId, (id) => host.conversation(p.conversationId, { live: true }).fork(p.at, id, p.title));
			case "conversations.archive": {
				const conversation = host.conversation(p.conversationId);
				conversation.archived = Boolean(p.archived);
				host.changed(conversation);
				return { conversation: conversation.summary() };
			}
			case "submit":
				if (typeof p.requestId !== "string" || typeof p.text !== "string") throw new Failure("bad_request", "submit needs requestId and text");
				return host.conversation(p.conversationId, { live: true }).submit(p);
			case "abort":
				await host.conversation(p.conversationId, { live: true }).abort();
				return {};
			case "configure": {
				const model = p.changes?.model;
				if (model && !MODELS.some((m) => m.provider === model.provider && m.modelId === model.modelId)) {
					throw new Failure("invalid_settings", `Unknown model ${model.provider}/${model.modelId}`);
				}
				return host.conversation(p.conversationId, { live: true }).configure(p.changes ?? {});
			}
			case "compact":
				return host.conversation(p.conversationId, { live: true }).compact(p.instructions);
			case "reset":
				return host.conversation(p.conversationId, { live: true }).reset(p.handoff);
			case "approval.answer": {
				const [conversationId] = String(p.approvalId).split(":");
				return host.conversation(Number(conversationId), { live: true }).answer(p.approvalId, p.decision, you.login);
			}
			case "conversation.history": {
				const conversation = host.conversation(p.conversationId);
				if (!conversation.isLive) return { items: [], hasEarlier: false };
				return conversation.history(p.before, p.limit ?? 100);
			}
			case "unsubscribe":
				subscriptions.get(p.subscription)?.();
				subscriptions.delete(p.subscription);
				return {};
			default:
				throw new Failure("unknown_method", `Unknown method ${method}`);
		}
	}
}

const sockets = new Set();
const server = createServer((request, response) => {
	if (request.method === "POST" && request.url === "/debug/drop") {
		const count = sockets.size;
		for (const ws of sockets) ws.destroy();
		log(`dropped ${count} connection(s)`);
		response.end(`dropped ${count}\n`);
		return;
	}
	response.writeHead(426, { "content-type": "text/plain" }).end("amyrlin mock server: connect with a WebSocket to /amyrlin\n");
});

server.on("upgrade", (request, socket) => {
	if (new URL(request.url, "http://localhost").pathname !== "/amyrlin") {
		socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
		return;
	}
	// A real server refuses requests without Tailscale identity (section 1). The mock accepts them for local use.
	const login = request.headers["tailscale-user-login"] ?? "local@mock";
	const ws = acceptUpgrade(request, socket);
	if (!ws) return;
	sockets.add(ws);
	ws.on("close", () => sockets.delete(ws));
	serve(ws, { login, name: request.headers["tailscale-user-name"] ?? "Local user" });
});

server.listen(PORT, "127.0.0.1", () => {
	log(`mock amyrlin server on ws://127.0.0.1:${PORT}/amyrlin with ${host.conversations.size} conversations (replay speed ${REPLAY_SPEED}x)`);
});
