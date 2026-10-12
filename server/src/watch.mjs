// conversation.watch: watchEvents() translated to protocol v1 frames (docs/protocol.md sections 6.1 and 7), enriched
// with what the durable stream does not carry, plus the server's own approval events.
import { watchEvents } from "@earendil-works/pi-durable";
import { context, settingsFrom } from "./host.mjs";
import { DurableTranslator } from "./translate.mjs";

/**
 * Starts one watch. `send(events)` sends one frame and returns a promise that settles once the socket has room again,
 * so a slow client slows this listener, and pi-durable replaces what it falls behind on with a snapshot (section 9.2).
 * Returns a function that stops the watch.
 */
export async function watchConversation(host, conversationId, send, snapshotItems) {
	const conversation = await host.conversation(conversationId);
	let effective = host.effective(await conversation.agent(context));
	let inbox = await host.inboxExtras(conversationId);
	const translator = new DurableTranslator({
		conversationId,
		conversation: () => {
			const summary = host.summaries.get(conversationId);
			return { id: conversationId, title: summary?.title ?? "", archived: summary?.archived ?? false, parent: summary?.parent ?? null };
		},
		inboxExtra: (id) => inbox.get(id),
		settings: (agent) => settingsFrom(agent, effective),
		approvals: () => host.approvals.forConversation(conversationId),
	});

	const stream = await watchEvents(host.harness, conversationId, context);
	let stopped = false;

	/** Refreshes enrichment the batch needs, translates it, and completes snapshots with older history. */
	const translate = async (events) => {
		const types = new Set(events.map((e) => e.type));
		if (types.has("snapshot") || types.has("inbox_update")) inbox = await host.inboxExtras(conversationId);
		if (types.has("snapshot") || types.has("agent_changed")) effective = host.effective(await conversation.agent(context));
		const out = translator.frames({ batch: events })[0] ?? [];
		for (const event of out) if (event.type === "snapshot") await completeSnapshot(event);
		return out;
	};

	/** At most `snapshotItems` items; fewer active ones are topped up with older history (section 6.1, step 2). */
	const completeSnapshot = async (snapshot) => {
		if (snapshot.items.length > snapshotItems) {
			snapshot.items = snapshot.items.slice(-snapshotItems);
			snapshot.hasEarlier = true;
			return;
		}
		const lowest = Math.min(...snapshot.items.map((item) => item.id));
		if (!Number.isFinite(lowest)) {
			// Nothing active: the newest page of history, if there is any (a conversation reset with no entries since).
			const page = await host.itemsBefore(conversation, Number.MAX_SAFE_INTEGER, snapshotItems);
			snapshot.items = page.items;
			snapshot.hasEarlier = page.hasEarlier;
			return;
		}
		const page = await host.itemsBefore(conversation, lowest, snapshotItems - snapshot.items.length);
		snapshot.items = [...page.items, ...snapshot.items];
		snapshot.hasEarlier = page.hasEarlier;
	};

	// The snapshot first, then batches, then approval events in their own frames (section 8).
	await send([...(await translate([stream.snapshot]))]);
	const onApproval = (id, event) => {
		if (id === conversationId && !stopped) void send([event]);
	};
	host.approvals.listeners.add(onApproval);
	stream.start(async (events) => {
		if (stopped) return;
		const out = await translate(events);
		if (out.length > 0) await send(out);
	});
	void stream.closed.then((end) => {
		if (!stopped && end.reason !== "stopped") host.log(`watch ${conversationId} ended: ${end.reason}`);
	});

	return async () => {
		stopped = true;
		host.approvals.listeners.delete(onApproval);
		await stream.stop();
	};
}

