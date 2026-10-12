// Drives a running mock server through the protocol with Node's built-in WebSocket client and checks what it sends.
//   node server.mjs &   node smoke.mjs
import assert from "node:assert/strict";

const url = process.env.URL ?? "ws://127.0.0.1:8787/amyrlin";
const ws = new WebSocket(url);
// Responses and everything else wait in separate queues, so awaiting a response never consumes events.
const responses = [];
const inbox = [];
let wake;
ws.onmessage = (message) => {
	const frame = JSON.parse(message.data);
	(frame.type === "response" ? responses : inbox).push(frame);
	wake?.();
};
await new Promise((resolve, reject) => {
	ws.onopen = resolve;
	ws.onerror = reject;
});

/** Consumes frames in order, testing each once, until one matches `test`. */
async function next(test, label, queue = inbox, timeoutMs = 10_000) {
	const deadline = Date.now() + timeoutMs;
	for (;;) {
		while (queue.length > 0) {
			const frame = queue.shift();
			if (test(frame)) return frame;
		}
		if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
		await new Promise((resolve) => {
			wake = resolve;
			setTimeout(resolve, 50);
		});
	}
}
let requestId = 0;
async function request(method, params = {}) {
	const id = `r${++requestId}`;
	ws.send(JSON.stringify({ type: "request", id, method, params }));
	const response = await next((f) => f.id === id, `response to ${method}`, responses);
	if (response.error) throw Object.assign(new Error(response.error.message), { code: response.error.code });
	return response.result;
}
const eventsOf = (subscription) => (f) => f.type === "event" && f.subscription === subscription;
async function waitForEvent(subscription, type, label = type) {
	const seen = [];
	await next((f) => {
		if (!eventsOf(subscription)(f)) return false;
		seen.push(...f.events);
		return f.events.some((e) => e.type === type);
	}, label);
	return seen;
}

ws.send(JSON.stringify({ type: "hello", protocols: [1], client: { name: "smoke", version: "0" } }));
const welcome = await next((f) => f.type === "welcome", "welcome");
assert.equal(welcome.protocol, 1);

const info = await request("host.info");
assert.ok(info.models.length > 0);

const hostWatch = await request("host.watch");
const hostSnapshot = await next(eventsOf(hostWatch.subscription), "host snapshot");
assert.equal(hostSnapshot.seq, 0);
assert.equal(hostSnapshot.events[0].type, "host.snapshot");
const conversations = hostSnapshot.events[0].conversations;
console.log(`host snapshot: ${conversations.length} conversations`);

// A replay streams its fixture from a snapshot, with seq rising by one.
const replay = conversations.find((c) => c.title.startsWith("Replay 02"));
const replayWatch = await request("conversation.watch", { conversationId: replay.id });
const replayed = [];
let seq = -1;
await next((f) => {
	if (!eventsOf(replayWatch.subscription)(f)) return false;
	assert.equal(f.seq, seq + 1);
	seq = f.seq;
	replayed.push(...f.events);
	return f.events.some((e) => e.type === "run.ended");
}, "replay to finish");
assert.equal(replayed[0].type, "snapshot");
console.log(`replay 02: ${seq + 1} frames, ${replayed.length} events`);
await assert.rejects(request("submit", { conversationId: replay.id, requestId: "x", text: "hi" }), /read-only/);

// A live conversation: submit, a duplicate submit, and a full run with a tool.
const created = await request("conversations.create", { requestId: "smoke-create", title: "Smoke" });
const again = await request("conversations.create", { requestId: "smoke-create" });
assert.equal(again.duplicate, true);
assert.equal(again.conversation.id, created.conversation.id);
const id = created.conversation.id;
const live = await request("conversation.watch", { conversationId: id });
await next(eventsOf(live.subscription), "live snapshot");
const submitted = await request("submit", { conversationId: id, requestId: "smoke-1", text: "count please" });
assert.equal(submitted.submission.status, "placed");
const duplicate = await request("submit", { conversationId: id, requestId: "smoke-1", text: "count please" });
assert.equal(duplicate.duplicate, true);
const run = await waitForEvent(live.subscription, "run.ended", "counted run");
const types = new Set(run.map((e) => e.type));
for (const type of ["stream.started", "stream.delta", "item.added", "tool.started", "tool.updated", "tool.ended", "spend.changed"]) {
	assert.ok(types.has(type), `run includes ${type}`);
}
console.log(`live run: ${run.length} events`);

// A steer while busy joins the run.
await request("submit", { conversationId: id, requestId: "smoke-2", text: "count again" });
await waitForEvent(live.subscription, "tool.started", "second tool");
const steer = await request("submit", { conversationId: id, requestId: "smoke-3", text: "and say done", whenBusy: "steer" });
assert.equal(steer.submission.status, "queued");
const steered = await waitForEvent(live.subscription, "run.ended", "steered run");
const ended = steered.find((e) => e.type === "run.ended");
assert.equal(ended.inputs.length, 2, "the steer joined the run");

// Approval, then deny.
await request("submit", { conversationId: id, requestId: "smoke-4", text: "delete the notes" });
const asked = await waitForEvent(live.subscription, "approval.requested");
const approval = asked.find((e) => e.type === "approval.requested").approval;
await request("approval.answer", { approvalId: approval.approvalId, decision: "deny" });
const denied = await waitForEvent(live.subscription, "run.ended", "denied run");
assert.ok(denied.some((e) => e.type === "item.added" && e.item.type === "toolResult" && e.item.diagnostics[0]?.code === "blocked"));

// Abort while an approval waits.
await request("submit", { conversationId: id, requestId: "smoke-5", text: "delete it again" });
await waitForEvent(live.subscription, "approval.requested");
await request("abort", { conversationId: id });
const aborted = await waitForEvent(live.subscription, "run.ended", "aborted run");
assert.ok(aborted.some((e) => e.type === "approval.resolved" && e.decision === "cancelled"));
assert.ok(aborted.some((e) => e.type === "item.added" && e.item.diagnostics?.[0]?.code === "aborted"));

// Abort mid-stream keeps the partial as an aborted assistant item.
await request("submit", { conversationId: id, requestId: "smoke-6", text: "explain at length" });
await waitForEvent(live.subscription, "stream.delta");
await request("abort", { conversationId: id });
const cut = await waitForEvent(live.subscription, "run.ended", "cut run");
assert.ok(cut.some((e) => e.type === "item.added" && e.item.stopReason === "aborted"));

// Long transcript: a 200-item window and history paging.
const long = conversations.find((c) => c.title.startsWith("Long transcript"));
const longWatch = await request("conversation.watch", { conversationId: long.id });
const longSnapshot = (await next(eventsOf(longWatch.subscription), "long snapshot")).events[0];
assert.equal(longSnapshot.items.length, 200);
assert.equal(longSnapshot.hasEarlier, true);
const page = await request("conversation.history", { conversationId: long.id, before: longSnapshot.items[0].id, limit: 100 });
assert.equal(page.items.length, 100);
assert.ok(page.items.at(-1).id < longSnapshot.items[0].id);

console.log("smoke test passed");
ws.close();
