// amyrlin server: protocol v1 (docs/protocol.md) over one WebSocket per client, on 127.0.0.1 behind tailscale serve.
//   AMYRLIN_CONFIG=~/.config/amyrlin/config.json node src/main.mjs
import { createServer } from "node:http";
import { loadConfig } from "./config.mjs";
import { Host, ProtocolError } from "./host.mjs";
import { watchConversation } from "./watch.mjs";
import { acceptUpgrade } from "./ws.mjs";

const LIMITS = { maxFrameBytes: 16 * 1024 * 1024, snapshotItems: 200 };
const log = (...parts) => console.log(new Date().toISOString(), ...parts);

const config = loadConfig();
const host = new Host(config, log);
await host.open();

/** RFC 2047 "Q" encoding, which tailscale serve may use for non-ASCII names (protocol section 1). */
function decodeHeader(value) {
	if (typeof value !== "string") return undefined;
	return value.replace(/=\?utf-8\?q\?([^?]*)\?=/gi, (_, encoded) =>
		Buffer.from(encoded.replace(/_/g, " ").replace(/=([0-9a-f]{2})/gi, (_m, hex) => String.fromCharCode(parseInt(hex, 16))), "latin1").toString("utf8"),
	);
}

function serve(ws, you) {
	let welcomed = false;
	let nextSubscription = 1;
	const subscriptions = new Map(); // id → stop()
	const sendFrame = (frame) => ws.send(JSON.stringify(frame));

	/** One subscription's frames, numbered, with backpressure from the socket. */
	const subscriber = (id) => {
		let seq = 0;
		return async (events) => {
			if (!subscriptions.has(id) || !ws.isOpen) return;
			sendFrame({ type: "event", subscription: id, seq: seq++, events });
			await ws.writable();
		};
	};

	ws.on("message", async (text) => {
		let frame;
		try {
			frame = JSON.parse(text);
		} catch {
			return ws.close(4400, "malformed frame");
		}
		if (!welcomed) {
			if (frame.type !== "hello") return ws.close(4400, "expected hello");
			if (!Array.isArray(frame.protocols) || !frame.protocols.includes(1)) {
				sendFrame({ type: "goodbye", reason: "unsupported_protocol", protocols: [1] });
				return ws.close(4406, "unsupported protocol");
			}
			welcomed = true;
			log(`hello from ${frame.client?.name ?? "?"} ${frame.client?.version ?? ""} as ${you.login}`);
			return sendFrame({ type: "welcome", protocol: 1, host: host.identity(), you, limits: LIMITS });
		}
		if (frame.type !== "request" || typeof frame.id !== "string") return;
		const respond = (result) => sendFrame({ type: "response", id: frame.id, result });
		const params = frame.params ?? {};
		try {
			switch (frame.method) {
				case "conversation.watch": {
					const id = `s${nextSubscription++}`;
					subscriptions.set(id, async () => {});
					const send = subscriber(id);
					// The response goes out before the first event frame (section 2.2): watchConversation sends the
					// snapshot only after this synchronous respond().
					await host.conversation(params.conversationId);
					respond({ subscription: id });
					try {
						const stop = await watchConversation(host, params.conversationId, send, LIMITS.snapshotItems);
						if (subscriptions.has(id)) subscriptions.set(id, stop);
						else await stop();
					} catch (error) {
						subscriptions.delete(id);
						sendFrame({ type: "end", subscription: id, reason: error instanceof ProtocolError && error.code === "not_found" ? "not_found" : "internal" });
						log(`watch ${params.conversationId} failed:`, error.message);
					}
					return;
				}
				case "host.watch": {
					const id = `s${nextSubscription++}`;
					const send = subscriber(id);
					const onSummary = (conversation) => void send([{ type: "conversation.updated", conversation }]);
					const onSpend = (spend) => void send([{ type: "host.spend", spend }]);
					subscriptions.set(id, async () => {
						host.summaryListeners.delete(onSummary);
						host.spendListeners.delete(onSpend);
					});
					respond({ subscription: id });
					await send([{ type: "host.snapshot", host: host.identity(), spend: await host.hostSpend(), conversations: host.listSummaries() }]);
					host.summaryListeners.add(onSummary);
					host.spendListeners.add(onSpend);
					return;
				}
				case "unsubscribe": {
					const stop = subscriptions.get(params.subscription);
					subscriptions.delete(params.subscription);
					await stop?.();
					return respond({});
				}
				default:
					return respond(await handle(frame.method, params));
			}
		} catch (error) {
			const known = error instanceof ProtocolError;
			if (!known) log(`${frame.method} failed:`, error);
			const payload = { code: known ? error.code : "internal", message: error.message, retryable: known ? error.retryable : false };
			if (known && error.data !== undefined) payload.data = error.data;
			sendFrame({ type: "response", id: frame.id, error: payload });
		}
	});

	ws.on("close", ({ code }) => {
		for (const stop of subscriptions.values()) void stop().catch(() => {});
		subscriptions.clear();
		log(`connection from ${you.login} closed (${code})`);
	});

	async function handle(method, p) {
		switch (method) {
			case "host.info":
				return {
					host: host.identity(),
					models: host.modelInfo(),
					tools: host.toolInfo(),
					defaults: { model: host.defaultModel, thinkingLevel: config.thinkingLevel },
				};
			case "conversations.list":
				return { conversations: host.listSummaries(p.includeArchived === true) };
			case "conversations.create":
				return host.create(p);
			case "conversations.fork":
				return host.fork(p);
			case "conversations.archive":
				return host.archive(p);
			case "submit":
				return host.submit(p);
			case "abort":
				return host.abort(p);
			case "configure":
				return host.configure(p);
			case "compact":
				return host.compact(p);
			case "reset":
				return host.reset(p);
			case "approval.answer":
				return host.answerApproval(p, you.login);
			case "conversation.history":
				return host.history(p);
			default:
				throw new ProtocolError("unknown_method", `Unknown method ${method}`);
		}
	}
}

const server = createServer((_request, response) => {
	response.writeHead(426, { "content-type": "text/plain" }).end("amyrlin server: connect with a WebSocket to /amyrlin\n");
});

server.on("upgrade", (request, socket) => {
	const path = new URL(request.url ?? "/", "http://localhost").pathname;
	if (path !== "/amyrlin") return void socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
	// Identity comes from tailscale serve, which strips client-supplied copies of these headers (section 1).
	const login = decodeHeader(request.headers["tailscale-user-login"]);
	if (login === undefined && !config.allowAnonymous) return void socket.end("HTTP/1.1 401 Unauthorized\r\n\r\n");
	if (login !== undefined && !config.allowAnonymous && !config.allowedLogins.includes(login)) {
		log(`refused ${login}`);
		return void socket.end("HTTP/1.1 403 Forbidden\r\n\r\n");
	}
	const ws = acceptUpgrade(request, socket);
	if (ws === null) return;
	serve(ws, { login: login ?? "anonymous@localhost", name: decodeHeader(request.headers["tailscale-user-name"]) ?? login ?? "Local" });
});

server.listen(config.port, "127.0.0.1", () => {
	log(`amyrlin server "${config.name}" on ws://127.0.0.1:${config.port}/amyrlin, store ${config.store}, model ${host.defaultModel.provider}/${host.defaultModel.modelId}`);
});

const shutdown = async (signal) => {
	log(`${signal}: shutting down`);
	server.close();
	await host.close();
	process.exit(0);
};
process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
