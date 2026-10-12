// Server settings, from a JSON file (AMYRLIN_CONFIG, default ~/.config/amyrlin/config.json).
// The model API key lives in its own file, never in the environment, so the agents' bash children cannot inherit it.
import { readFileSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join, resolve } from "node:path";

const home = (path) => (path.startsWith("~/") ? join(homedir(), path.slice(2)) : path);

export const DEFAULT_CONFIG_PATH = join(homedir(), ".config/amyrlin/config.json");

/**
 * @typedef {object} Config
 * @property {number} port              Listens on 127.0.0.1 only; tailscale serve proxies to it.
 * @property {string} store             SQLite file.
 * @property {string} name              Shown in the app's sidebar.
 * @property {string[]} allowedLogins   Tailscale logins that may connect.
 * @property {boolean} allowAnonymous   Accept connections without Tailscale identity headers. Local development only.
 * @property {"anthropic" | "faux"} provider
 * @property {string} apiKeyFile        Holds the provider's API key.
 * @property {{ provider: string, modelId: string }} model   Default model.
 * @property {string[] | undefined} models  Model IDs offered in the app; absent: every model of the provider.
 * @property {string} thinkingLevel     Default thinking level.
 * @property {string} cwd               Default working directory.
 * @property {string[]} requireApproval Tools that wait for approval in the app.
 * @property {number | undefined} compactionWindowTokens  Context window compaction plans with (see host.mjs).
 * @property {string} instructions      Prepended to every conversation's system prompt.
 */

/** @returns {Config} */
export function loadConfig(path = process.env.AMYRLIN_CONFIG ?? DEFAULT_CONFIG_PATH) {
	const file = resolve(home(path));
	const raw = JSON.parse(readFileSync(file, "utf8"));
	const relative = (value) => resolve(dirname(file), home(value));
	const provider = raw.provider ?? "anthropic";
	const config = {
		port: raw.port ?? 8420,
		store: relative(raw.store ?? "~/.local/share/amyrlin/store.sqlite"),
		name: raw.name ?? hostname().split(".")[0],
		allowedLogins: raw.allowedLogins ?? [],
		allowAnonymous: raw.allowAnonymous === true,
		provider,
		apiKeyFile: relative(raw.apiKeyFile ?? "~/.config/amyrlin/anthropic-api-key"),
		model: raw.model ?? (provider === "faux" ? { provider: "faux", modelId: "faux-1" } : { provider: "anthropic", modelId: "claude-sonnet-5-5" }),
		models: raw.models,
		thinkingLevel: raw.thinkingLevel ?? "medium",
		cwd: home(raw.cwd ?? "~"),
		requireApproval: raw.requireApproval ?? ["bash", "write", "edit"],
		compactionWindowTokens: raw.compactionWindowTokens,
		instructions: raw.instructions ?? "You are a coding agent working on this machine for its owner, who talks to you through the amyrlin app. Be concise.",
	};
	const errors = [];
	if (!["anthropic", "faux"].includes(config.provider)) errors.push(`provider must be "anthropic" or "faux", not ${config.provider}`);
	if (!config.allowAnonymous && config.allowedLogins.length === 0) errors.push("allowedLogins is empty, so nobody could connect");
	if (errors.length > 0) throw new Error(`${file}:\n  ${errors.join("\n  ")}`);
	return config;
}

/** The provider's API key, read when a request needs it, so a replaced key file takes effect without a restart. */
export function readApiKey(config) {
	try {
		return readFileSync(config.apiKeyFile, "utf8").trim() || undefined;
	} catch {
		return undefined;
	}
}
