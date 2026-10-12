// End-to-end test against a running server with the faux model (test/dev-config.json):
//   pnpm run dev &   node test/e2e.mjs [ws://127.0.0.1:8421/amyrlin]
import assert from "node:assert/strict";

const url = process.argv[2] ?? "ws://127.0.0.1:8421/amyrlin";

export async function connect(target = url) {
	const ws = new WebSocket(target);
	// One queue for responses, one per subscription, one for everything else.
	const responses = [];
	const frames = [];
	const bySubscription = new Map();
	const queueFor = (subscription) => {
		if (!bySubscription.has(subscription)) bySubscription.set(subscription, []);
		return bySubscription.get(subscription);
	};
	let wake;
	ws.onmessage = (message) => {
		const frame = JSON.parse(message.data);
		if (frame.type === "response") responses.push(frame);
		else if (frame.type === "event") queueFor(frame.subscription).push(frame);
		else frames.push(frame);
		wake?.();
	};
	await new Promise((resolve, reject) => {
		ws.onopen = resolve;
		ws.onerror = () => reject(new Error(`cannot connect to ${target}`));
	});
	const next = async (test, label, queue = frames, timeoutMs = 15_000) => {
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
	};
	let requestId = 0;
	const request = async (method, params = {}) => {
		const id = `r${++requestId}`;
		ws.send(JSON.stringify({ type: "request", id, method, params }));
		const response = await next((f) => f.id === id, `response to ${method}`, responses);
		if (response.error) throw Object.assign(new Error(response.error.message), { code: response.error.code });
		return response.result;
	};
	/** Collects a subscription's events until one matches `test`; checks seq. */
	const seqs = new Map();
	const until = async (subscription, test, label) => {
		const seen = [];
		await next((f) => {
			assert.equal(f.seq, seqs.get(subscription) ?? 0, `${subscription} seq`);
			seqs.set(subscription, f.seq + 1);
			seen.push(...f.events);
			return f.events.some(test);
		}, label, queueFor(subscription));
		return seen;
	};
	ws.send(JSON.stringify({ type: "hello", protocols: [1], client: { name: "e2e", version: "0" } }));
	const welcome = await next((f) => f.type === "welcome", "welcome");
	return { ws, request, until, welcome };
}

const type = (t) => (e) => e.type === t;

if (import.meta.url === `file://${process.argv[1]}`) {
	const { ws, request, until, welcome } = await connect();
	assert.equal(welcome.protocol, 1);
	assert.match(welcome.host.hostId, /^[0-9a-f-]{36}$/);

	const info = await request("host.info");
	assert.ok(info.models.length > 0);
	assert.deepEqual(info.tools.filter((t) => t.requiresApproval).map((t) => t.name).sort(), ["bash", "edit", "write"]);

	const hostWatch = (await request("host.watch")).subscription;
	await until(hostWatch, type("host.snapshot"), "host snapshot");

	const created = await request("conversations.create", { requestId: `e2e-${Date.now()}`, title: "e2e" });
	const again = await request("conversations.create", { requestId: created.conversation.title === "e2e" ? undefined : "x" }).catch((e) => e);
	assert.equal(again.code, "bad_request");
	const id = created.conversation.id;
	assert.equal(created.conversation.title, "e2e");

	const watch = (await request("conversation.watch", { conversationId: id })).subscription;
	const [snapshot] = await until(watch, type("snapshot"), "snapshot");
	assert.equal(snapshot.conversation.title, "e2e");
	assert.deepEqual(snapshot.items, []);
	assert.equal(snapshot.settings.effective.model.modelId, "faux-1");

	// 1. A plain answer, and a duplicate submit.
	const first = await request("submit", { conversationId: id, requestId: "e2e-1", text: "hello there" });
	assert.equal(first.duplicate, false);
	const duplicate = await request("submit", { conversationId: id, requestId: "e2e-1", text: "hello there" });
	assert.equal(duplicate.duplicate, true);
	assert.equal(duplicate.submission.id, first.submission.id);
	const plain = await until(watch, type("run.ended"), "plain run");
	assert.ok(plain.some((e) => e.type === "stream.started"));
	assert.ok(plain.some((e) => e.type === "item.added" && e.item.type === "assistant" && e.item.stopReason === "stop"));
	console.log(`plain answer: ${plain.length} events`);

	// 2. bash needs approval; approve it.
	await request("submit", { conversationId: id, requestId: "e2e-2", text: "run bash please" });
	const asked = await until(watch, type("approval.requested"), "approval");
	const approval = asked.find(type("approval.requested")).approval;
	assert.equal(approval.toolName, "bash");
	assert.equal(approval.approvalId, `${id}:${approval.callId}`);
	const summary = await until(hostWatch, (e) => e.type === "conversation.updated" && e.conversation.id === id && e.conversation.status === "needsApproval", "needsApproval status");
	assert.ok(summary.length > 0);
	const answered = await request("approval.answer", { approvalId: approval.approvalId, decision: "approve" });
	assert.equal(answered.approval.decision, "approve");
	assert.equal(answered.approval.by, "anonymous@localhost");
	const repeat = await request("approval.answer", { approvalId: approval.approvalId, decision: "approve" });
	assert.equal(repeat.approval.decision, "approve");
	await assert.rejects(request("approval.answer", { approvalId: approval.approvalId, decision: "deny" }), (e) => e.code === "already_resolved");
	const ran = await until(watch, type("run.ended"), "approved run");
	assert.ok(ran.some(type("tool.started")));
	const result = ran.find((e) => e.type === "item.added" && e.item.type === "toolResult");
	assert.equal(result.item.isError, false);
	assert.match(result.item.content[0].text, /hello from/);
	console.log(`approved bash: ${result.item.content[0].text.split("\n")[0]}`);

	// 3. Deny.
	await request("submit", { conversationId: id, requestId: "e2e-3", text: "bash again" });
	const asked2 = await until(watch, type("approval.requested"), "second approval");
	await request("approval.answer", { approvalId: asked2.find(type("approval.requested")).approval.approvalId, decision: "deny", message: "not now" });
	const denied = await until(watch, type("run.ended"), "denied run");
	const blocked = denied.find((e) => e.type === "item.added" && e.item.type === "toolResult");
	assert.equal(blocked.item.diagnostics[0].code, "blocked");
	assert.match(blocked.item.content[0].text, /Denied by anonymous@localhost: not now/);

	// 4. Esc while an approval waits.
	await request("submit", { conversationId: id, requestId: "e2e-4", text: "bash a third time" });
	await until(watch, type("approval.requested"), "third approval");
	await request("abort", { conversationId: id });
	const aborted = await until(watch, type("run.ended"), "aborted run");
	assert.ok(aborted.some((e) => e.type === "approval.resolved" && e.decision === "cancelled"));
	assert.ok(aborted.some((e) => e.type === "item.added" && e.item.diagnostics?.[0]?.code === "aborted"));
	assert.ok(aborted.some((e) => e.type === "submission" && e.submission.reason === "aborted"));

	// 5. Configure, reset, compact.
	const configured = await request("configure", { conversationId: id, changes: { thinkingLevel: "high", cwd: "/tmp" } });
	assert.equal(configured.settings.stored.thinkingLevel, "high");
	assert.equal(configured.settings.effective.cwd, "/tmp");
	await until(watch, (e) => e.type === "settings.changed" && e.settings.effective.cwd === "/tmp", "settings.changed");
	await assert.rejects(request("configure", { conversationId: id, changes: { model: { provider: "nope", modelId: "x" } } }), (e) => e.code === "invalid_settings");
	await request("configure", { conversationId: id, changes: { thinkingLevel: null, cwd: null } });
	const compacted = await request("compact", { conversationId: id });
	assert.equal(typeof compacted.taskId, "number");
	await until(watch, type("compaction.ended"), "compaction");

	// 6. A second watcher gets a snapshot with the whole history; history paging works.
	const second = (await request("conversation.watch", { conversationId: id })).subscription;
	const [late] = await until(second, type("snapshot"), "late snapshot");
	assert.ok(late.items.length >= 8, `late snapshot has ${late.items.length} items`);
	assert.equal(late.run, null);
	const page = await request("conversation.history", { conversationId: id, before: late.items.at(-1).id, limit: 2 });
	assert.equal(page.items.length, 2);
	assert.equal(page.hasEarlier, true);

	// 7. Errors.
	await assert.rejects(request("submit", { conversationId: 999_999, requestId: "x", text: "x" }), (e) => e.code === "not_found");
	await assert.rejects(request("no.such.method"), (e) => e.code === "unknown_method");

	// Summaries are coalesced to four updates a second (protocol section 6.2), so poll briefly.
	let settled = false;
	for (let i = 0; i < 20 && !settled; i++) {
		const list = await request("conversations.list");
		settled = list.conversations.some((c) => c.id === id && c.status === "idle" && c.spend.total > 0 && c.title === "e2e");
		if (!settled) await new Promise((resolve) => setTimeout(resolve, 100));
	}
	assert.ok(settled, "the conversation's summary settles to idle with spend");
	await request("conversations.archive", { conversationId: id, archived: true });
	assert.ok(!(await request("conversations.list")).conversations.some((c) => c.id === id));

	console.log("e2e passed");
	ws.close();
}
