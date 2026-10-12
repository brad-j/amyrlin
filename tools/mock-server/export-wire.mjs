// Writes every fixture's protocol v1 translation to fixtures/wire-v1/<name>.jsonl, one frame (an array of events)
// per line. A Swift test compares these with the Swift test mapper, so the two translations cannot drift apart.
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { translateFixture } from "../../server/src/translate.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const source = join(root, "fixtures/durable-1.1.0");
const target = join(root, "fixtures/wire-v1");
await mkdir(target, { recursive: true });
for (const file of (await readdir(source)).filter((name) => name.endsWith(".jsonl")).sort()) {
	const frames = translateFixture(await readFile(join(source, file), "utf8"));
	await writeFile(join(target, file), frames.map((frame) => JSON.stringify(frame.events)).join("\n") + "\n");
	console.error(`${file}: ${frames.length} frames`);
}
