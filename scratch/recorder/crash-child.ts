// One process of scenario 11, started by record.ts. Prints recorder lines to stdout.
//   run <db>:    open the SQLite store, attach, submit req-11; record.ts kills this process mid-tool.
//   resume <db>: reopen the store, attach, resubmit req-11 (finds the same submission), resume(), wait for idle.
// Scenario 15 (approval during a crash):
//   approval-run <db>:    submit req-15; a beforeTool hook on delete_file waits forever; record.ts kills it there.
//   approval-resume <db>: reopen, attach, resume(); if the hook runs again, approve it after 300 ms.
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { hook, ToolTask } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { context, lastUser, open, pause, Recorder } from "./lib.ts";

const [mode, db] = process.argv.slice(2);
const modes = ["run", "resume", "approval-run", "approval-resume"];
if (db === undefined || !modes.includes(mode ?? "")) throw new Error(`usage: crash-child.ts ${modes.join("|")} <db>`);

const rec = new Recorder((line) => process.stdout.write(`${line}\n`));
const request = { type: "input", content: "Count to twenty.", requestId: "req-11" } as const;

/** Notes each entry; in approval-resume, approves 300 ms after entering. */
const approvalHook = hook(ToolTask, {
	beforeTool: async (call) => {
		if (call.name !== "delete_file") return undefined;
		rec.note("beforeTool hook entered; waiting for a decision", { toolCallId: call.id, pid: process.pid });
		if (mode === "approval-run") await new Promise(() => {});
		await pause(300);
		rec.note("approved");
		return undefined;
	},
});

if (mode === "approval-run" || mode === "approval-resume") {
	const { harness, root } = await open({
		storage: await openNodeSqliteStorage(db),
		hooks: [approvalHook],
		responses:
			mode === "approval-run"
				? [fauxAssistantMessage([fauxToolCall("delete_file", { path: "/tmp/notes.txt" }, { id: "call-1" })], { stopReason: "toolUse" })]
				: [fauxAssistantMessage("Deleted /tmp/notes.txt.")],
	});
	const stream = await rec.attach(harness, root.id);
	if (mode === "approval-run") {
		const submission = await root.submit({ type: "input", content: "Delete /tmp/notes.txt.", requestId: "req-15" }, context);
		rec.note("submitted", { submissionId: submission.id, requestId: "req-15" });
		await pause(60_000);
	} else {
		harness.resume();
		rec.note("resume() called");
		await harness.waitForIdle(context);
		await pause(20);
		await stream.stop();
		await harness.close(context);
	}
} else if (mode === "run") {
	const { harness, root } = await open({
		storage: await openNodeSqliteStorage(db),
		responses: [fauxAssistantMessage([fauxToolCall("count", { n: 20, delayMs: 100 }, { id: "call-1" })], { stopReason: "toolUse" })],
	});
	await rec.attach(harness, root.id);
	const submission = await root.submit(request, context);
	rec.note("submitted", { submissionId: submission.id, requestId: request.requestId });
	// Never returns normally: the parent kills this process.
	await submission.wait(context);
	await pause(60_000);
} else {
	const { harness, root } = await open({
		storage: await openNodeSqliteStorage(db),
		responses: [
			(transcript) => {
				const last = transcript.messages.at(-1);
				return fauxAssistantMessage(
					`The count was interrupted (${last?.role === "toolResult" && last.isError ? "error result" : "no error"}). You asked: "${lastUser(transcript)}"`,
				);
			},
		],
	});
	const stream = await rec.attach(harness, root.id);
	const again = await root.submit(request, context);
	rec.note("resubmitted the same requestId", { submissionId: again.id, requestId: request.requestId });
	harness.resume();
	rec.note("resume() called");
	await harness.waitForIdle(context);
	await pause(20);
	await stream.stop();
	await harness.close(context);
}
