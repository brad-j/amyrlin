// Records one conversation's frames from a running dev server (faux model) to fixtures/server-v1/session.jsonl, one
// frame's events per line. The Swift test ServerCaptureTests decodes and reduces them, so the app is checked against
// what this server sends, not only against the fixture translation.
//   pnpm run dev &   node test/capture.mjs
import { writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { connect } from "./e2e.mjs";

const out = fileURLToPath(new URL("../../fixtures/server-v1/", import.meta.url));
const { ws, request, until } = await connect(process.argv[2]);
const type = (t) => (e) => e.type === t;

const id = (await request("conversations.create", { requestId: `capture-${Date.now()}`, title: "Captured session" })).conversation.id;
const frames = [];
// A second socket records the subscription with its frame boundaries intact.
const recorder = new WebSocket(process.argv[2] ?? "ws://127.0.0.1:8421/amyrlin");
await new Promise((resolve) => (recorder.onopen = resolve));
recorder.onmessage = (message) => {
	const frame = JSON.parse(message.data);
	if (frame.type === "event") frames.push(frame.events);
};
recorder.send(JSON.stringify({ type: "hello", protocols: [1], client: { name: "capture", version: "0" } }));
recorder.send(JSON.stringify({ type: "request", id: "w", method: "conversation.watch", params: { conversationId: id } }));

const watch = (await request("conversation.watch", { conversationId: id })).subscription;
await until(watch, type("snapshot"), "snapshot");
await request("submit", { conversationId: id, requestId: "c1", text: "hello" });
await until(watch, type("run.ended"), "plain");
await request("submit", { conversationId: id, requestId: "c2", text: "run bash" });
const asked = await until(watch, type("approval.requested"), "approval");
await request("submit", { conversationId: id, requestId: "c3", text: "and a follow-up" });
await request("approval.answer", { approvalId: asked.find(type("approval.requested")).approval.approvalId, decision: "approve" });
await until(watch, (e) => e.type === "run.ended" && e.inputs.length === 1, "bash run");
await until(watch, type("run.ended"), "follow-up run");
await request("configure", { conversationId: id, changes: { thinkingLevel: "high" } });
await until(watch, type("settings.changed"), "settings");
await request("submit", { conversationId: id, requestId: "c4", text: "bash once more" });
await until(watch, type("approval.requested"), "second approval");
await request("abort", { conversationId: id });
await until(watch, type("run.ended"), "aborted");
await request("reset", { conversationId: id, handoff: "Starting over." });
await until(watch, (e) => e.type === "item.added" && e.item.type === "reset", "reset");
await new Promise((resolve) => setTimeout(resolve, 300));

mkdirSync(out, { recursive: true });
writeFileSync(`${out}session.jsonl`, frames.map((events) => JSON.stringify(events)).join("\n") + "\n");
console.log(`captured ${frames.length} frames from conversation ${id}`);
recorder.close();
ws.close();
