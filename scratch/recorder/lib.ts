// Shared setup for the fixture recorder: a faux model, deterministic tools, and a JSONL writer for watchEvents().
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord";
import { Type, type FauxResponseStep, type TranscriptContext } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxProvider, type RegisterFauxProviderOptions } from "@earendil-works/pi-ai/providers/faux";
import {
	createRegistry,
	defineExtension,
	defineTool,
	Harness,
	type HarnessSettings,
	type HookRegistration,
	type Storage,
	watchEvents,
	type AgentEvent,
	type AgentEventStream,
} from "@earendil-works/pi-durable";

export const context = BACKGROUND_CONTEXT;
/** Text of the newest user message the model sees. */
export const lastUser = (transcript: TranscriptContext): string => {
	const message = transcript.messages.findLast((m) => m.role === "user");
	const content = message?.content;
	if (typeof content === "string") return content;
	return (content ?? []).map((c) => (c.type === "text" ? c.text : "")).join("");
};

export const MODEL = { provider: "faux", modelId: "faux-1" } as const;

export const pause = (ms: number, ctx?: Context): Promise<void> =>
	new Promise((resolve, reject) => {
		const signal = ctx?.abortSignal;
		if (signal?.aborted) return reject(signal.reason ?? new Error("aborted"));
		const timer = setTimeout(() => {
			signal?.removeEventListener("abort", onAbort);
			resolve();
		}, ms);
		const onAbort = () => {
			clearTimeout(timer);
			reject(signal?.reason ?? new Error("aborted"));
		};
		signal?.addEventListener("abort", onAbort, { once: true });
	});

/** `count`: prints 1..n, one line every `delayMs`, honouring abort. */
export const countTool = defineTool({
	name: "count",
	description: "Count from 1 to n, one line at a time",
	parameters: Type.Object({ n: Type.Number(), delayMs: Type.Optional(Type.Number()) }),
	execute: async (args, api, ctx) => {
		for (let i = 1; i <= args.n; i++) {
			api.output(`${i}\n`);
			await pause(args.delayMs ?? 80, ctx);
		}
		await api.details({ counted: args.n }, ctx);
		return {};
	},
});

/** `lookup`: answers at once with structured details. */
export const lookupTool = defineTool({
	name: "lookup",
	description: "Look up a city's population",
	parameters: Type.Object({ city: Type.String() }),
	execute: async (args, api, ctx) => {
		await pause(30, ctx);
		const population = { Lisbon: 545_000, Porto: 232_000, Braga: 193_000 }[args.city] ?? 0;
		await api.details({ city: args.city, population }, ctx);
		return { content: [{ type: "text", text: `${args.city}: ${population}` }] };
	},
});

/** `delete_file`: never meant to run; scenario 8 blocks it with a hook. */
export const deleteTool = defineTool({
	name: "delete_file",
	description: "Delete a file",
	parameters: Type.Object({ path: Type.String() }),
	execute: async (args) => ({ content: [{ type: "text", text: `deleted ${args.path}` }] }),
});

export type Setup = {
	storage: Storage;
	responses: FauxResponseStep[];
	faux?: RegisterFauxProviderOptions;
	settings?: HarnessSettings;
	hooks?: HookRegistration[];
	agent?: Parameters<Harness["root"]>[1] extends infer O ? (O extends { agent?: infer A } ? A : never) : never;
};

export async function open(setup: Setup) {
	const faux = fauxProvider({
		// Slow enough that one answer spans several 100 ms partial commits.
		tokensPerSecond: 50,
		tokenSize: { min: 1, max: 3 },
		// Faux always reports cost 0 (pi-ai providers/faux.js), so no cost is configured here.
		models: [{ id: "faux-1", reasoning: true, contextWindow: 200_000, maxTokens: 8_000 }],
		...setup.faux,
	});
	faux.setResponses(setup.responses);
	const models = createModels();
	models.setProvider(faux.provider);
	const registry = createRegistry();
	registry.install(
		defineExtension({ name: "fixture-tools", tools: [countTool, lookupTool, deleteTool], hooks: setup.hooks ?? [] }),
	);
	const harness = await Harness.open(setup.storage, { models, registry, settings: setup.settings }, context);
	const root = await harness.root(context, { agent: { model: MODEL, ...setup.agent } });
	return { harness, root, faux };
}

export type Line = Record<string, unknown>;

/** Writes one JSON object per line, stamped with ms since the recorder started this scenario. */
export class Recorder {
	readonly lines: string[] = [];
	private readonly start = performance.now();
	private readonly sink?: (line: string) => void;
	constructor(sink?: (line: string) => void) {
		this.sink = sink;
	}
	private waiters: { test: (event: AgentEvent) => boolean; resolve: () => void }[] = [];
	write(line: Line): void {
		const text = JSON.stringify({ t: Math.round(performance.now() - this.start), ...line });
		this.lines.push(text);
		this.sink?.(text);
		const events = (line.batch as AgentEvent[] | undefined) ?? [];
		this.waiters = this.waiters.filter((waiter) => {
			if (!events.some(waiter.test)) return true;
			waiter.resolve();
			return false;
		});
	}
	/** Resolves once a later batch holds an event matching `test`. */
	waitFor(test: (event: AgentEvent) => boolean): Promise<void> {
		return new Promise((resolve) => this.waiters.push({ test, resolve }));
	}
	note(note: string, data?: unknown): void {
		this.write(data === undefined ? { note } : { note, data });
	}
	/** Attach watchEvents(): one `snapshot` line, then one `batch` line per commit, then `end`. */
	/** `stallFirstBatchMs` holds the listener on its first batch, so the stream falls behind and overflows. */
	async attach(
		harness: Harness,
		conversationId: Parameters<typeof watchEvents>[1],
		options: { stallFirstBatchMs?: number } = {},
	): Promise<AgentEventStream> {
		const stream = await watchEvents(harness, conversationId, context);
		this.write({ snapshot: stream.snapshot });
		let stall = options.stallFirstBatchMs;
		stream.start(async (events) => {
			this.write({ batch: events });
			if (stall !== undefined) {
				this.note("listener stalled", { ms: stall });
				await pause(stall);
				stall = undefined;
				this.note("listener resumed");
			}
		});
		void stream.closed.then((end) => this.write({ end }));
		return stream;
	}
}
