/**
 * Remote Model Management: shared pure logic + settings.json IO for the
 * server default model (Pi 0.85.1: `defaultProvider` / `defaultModel` /
 * `defaultThinkingLevel` in <agentDir>/settings.json — startup defaults,
 * applied at next Pi start).
 *
 * This file NEVER spawns processes and NEVER touches the network. Callers
 * (the HTTP daemon routes, the server-side extension tool) own subprocess
 * execution (`pi --list-models`, `pi auth check --provider P --json
 * --no-refresh` with fixed/allowlisted args only) and pass parsed data in.
 *
 * Security: settings.json lives ONLY under the daemon's agentDir
 * (PI_CODING_AGENT_DIR, e.g. C:\PiServer\data). No secrets are ever read
 * into these structures and none are returned: model rows carry catalog
 * metadata only; auth state is boolean + source label.
 *
 * No enums / namespaces: must survive Node native type-stripping.
 */
import { join } from "node:path";
import { existsSync } from "node:fs";
import { atomicWriteJson, backupFile, readJsonFile } from "./store.ts";

/** Thinking levels supported by Pi 0.85.1 (core/defaults.js). */
export const THINKING_LEVELS = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
] as const;

export type ThinkingLevel = (typeof THINKING_LEVELS)[number];

export function isValidThinkingLevel(v: unknown): v is ThinkingLevel {
  return (
    typeof v === "string" && (THINKING_LEVELS as readonly string[]).includes(v)
  );
}

/** One row of `pi --list-models` (catalog metadata only, no secrets). */
export interface PiModelInfo {
  provider: string;
  id: string;
  name: string | null;
  thinking: boolean;
  images: boolean;
  /** Display strings as printed by the CLI (e.g. "128K"); not raw numbers. */
  context: string;
  maxOut: string;
}

export interface ConfiguredDefault {
  provider: string | null;
  model: string | null;
  thinkingLevel: string | null;
  settingsPath: string;
  source: "settings.json" | "unset";
}

export interface SelectionInput {
  provider?: unknown;
  model?: unknown;
}

export type NormalizeResult =
  | { ok: true; provider: string; model: string }
  | { ok: false; error: string };

const MAX_TABLE_ROWS = 200;

function splitColumns(line: string): string[] {
  return line
    .split(/ {2,}|\t+/)
    .map((c) => c.trim())
    .filter((c) => c.length > 0);
}

/**
 * Parse `pi --list-models` table output deterministically. The header row
 * must be exactly [provider, model, context, max-out, thinking, images];
 * yes/no columns must be yes/no. Anything else -> error (never guess).
 */
export function parseListModelsTable(stdout: string):
  | {
      ok: true;
      models: PiModelInfo[];
    }
  | { ok: false; error: string } {
  const lines = stdout
    .split(/\r?\n/)
    .map((l) => l.replace(/\s+$/, ""))
    .filter((l) => l.trim().length > 0);
  if (lines.length === 0) return { ok: true, models: [] };
  const header = splitColumns(lines[0]);
  const want = [
    "provider",
    "model",
    "context",
    "max-out",
    "thinking",
    "images",
  ];
  if (
    header.length !== want.length ||
    !want.every((h, i) => header[i]?.toLowerCase() === h)
  ) {
    return { ok: false, error: "table_header_mismatch" };
  }
  const models: PiModelInfo[] = [];
  for (const line of lines.slice(1, MAX_TABLE_ROWS + 1)) {
    const cols = splitColumns(line);
    if (cols.length !== 6) return { ok: false, error: "table_row_mismatch" };
    const [provider, id, context, maxOut, thinking, images] = cols as [
      string,
      string,
      string,
      string,
      string,
      string,
    ];
    if (!provider || !id) return { ok: false, error: "table_row_mismatch" };
    if (thinking.toLowerCase() !== "yes" && thinking.toLowerCase() !== "no") {
      return { ok: false, error: "table_row_mismatch" };
    }
    if (images.toLowerCase() !== "yes" && images.toLowerCase() !== "no") {
      return { ok: false, error: "table_row_mismatch" };
    }
    // Name is not printed by the CLI table (only id); callers keep null.
    // Hmm: keep the id; name stays null unless a richer source is added.
    models.push({
      provider,
      id,
      name: null,
      thinking: thinking.toLowerCase() === "yes",
      images: images.toLowerCase() === "yes",
      context,
      maxOut,
    });
  }
  return { ok: true, models };
}

/**
 * Normalize + validate a {provider?, model} selection against a live model
 * list, mirroring Pi's own resolveCliModel rules (verified on 0.85.1):
 * trim, case-insensitive provider lookup, "provider/model" slash inference,
 * exact id match (case-insensitive), ambiguity rejection. `authedProviders`
 * (canonical ids with ready auth) breaks exact-id ties like Pi does.
 * Returns canonical provider spelling from the catalog.
 */
export function normalizeSelection(
  input: SelectionInput,
  models: PiModelInfo[],
  authedProviders?: string[],
): NormalizeResult {
  const rawProvider =
    typeof input.provider === "string" ? input.provider.trim() : "";
  const rawModel = typeof input.model === "string" ? input.model.trim() : "";
  if (rawModel.length === 0) return { ok: false, error: "model_required" };
  if (models.length === 0) return { ok: false, error: "no_models_available" };

  const providerMap = new Map<string, string>();
  for (const m of models) {
    if (!providerMap.has(m.provider.toLowerCase())) {
      providerMap.set(m.provider.toLowerCase(), m.provider);
    }
  }
  let provider = rawProvider
    ? (providerMap.get(rawProvider.toLowerCase()) ?? null)
    : null;
  if (rawProvider && !provider) {
    const known = [...providerMap.values()].sort((a, b) => a.localeCompare(b));
    return {
      ok: false,
      error: `unknown_provider:${rawProvider} (available: ${known.join(", ") || "none"})`,
    };
  }

  let pattern = rawModel;
  if (provider) {
    const prefix = `${provider}/`;
    if (pattern.toLowerCase().startsWith(prefix.toLowerCase())) {
      pattern = pattern.substring(prefix.length).trim();
      if (pattern.length === 0) return { ok: false, error: "model_required" };
    }
  } else {
    const slash = rawModel.indexOf("/");
    if (slash !== -1) {
      const maybe = rawModel.substring(0, slash);
      const canonical = providerMap.get(maybe.toLowerCase());
      if (canonical) {
        provider = canonical;
        pattern = rawModel.substring(slash + 1).trim();
        if (pattern.length === 0) return { ok: false, error: "model_required" };
      }
    }
  }

  const scope = provider
    ? models.filter((m) => m.provider === provider)
    : models;
  const lower = pattern.toLowerCase();
  const exact = scope.filter(
    (m) =>
      m.id.toLowerCase() === lower ||
      `${m.provider}/${m.id}`.toLowerCase() === lower,
  );
  if (exact.length === 1) {
    return { ok: true, provider: exact[0].provider, model: exact[0].id };
  }
  if (exact.length > 1) {
    if (authedProviders && authedProviders.length > 0) {
      const authed = exact.filter((m) => authedProviders.includes(m.provider));
      if (authed.length === 1) {
        return { ok: true, provider: authed[0].provider, model: authed[0].id };
      }
    }
    const cands = exact
      .map((m) => `${m.provider}/${m.id}`)
      .sort((a, b) => a.localeCompare(b))
      .join(", ");
    return { ok: false, error: `model_ambiguous:${pattern} (${cands})` };
  }
  const hint = provider
    ? `provider ${provider}`
    : "any provider (no exact id match)";
  return { ok: false, error: `model_not_found:${pattern} (${hint})` };
}

/** settings.json path. ALWAYS under the daemon's agentDir, never ~/.pi. */
export function piSettingsPath(agentDir: string): string {
  return join(agentDir, "settings.json");
}

/**
 * Read the configured startup default. Missing file -> nulls with
 * source "unset". Corrupt/non-object file -> throws (fail closed, mirroring
 * Pi's own refusal to overwrite on load error).
 */
export function readConfiguredDefault(agentDir: string): ConfiguredDefault {
  const settingsPath = piSettingsPath(agentDir);
  if (!existsSync(settingsPath)) {
    return {
      provider: null,
      model: null,
      thinkingLevel: null,
      settingsPath,
      source: "unset",
    };
  }
  let raw: unknown;
  try {
    raw = readJsonFile<unknown>(settingsPath, undefined);
  } catch {
    throw new Error("settings_corrupt");
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error("settings_corrupt");
  }
  const rec = raw as Record<string, unknown>;
  const strOrNull = (v: unknown): string | null =>
    typeof v === "string" && v.length > 0 ? v : null;
  const thinking = strOrNull(rec["defaultThinkingLevel"]);
  return {
    provider: strOrNull(rec["defaultProvider"]),
    model: strOrNull(rec["defaultModel"]),
    thinkingLevel:
      thinking !== null && isValidThinkingLevel(thinking) ? thinking : null,
    settingsPath,
    source: "settings.json",
  };
}

export interface WriteDefaultInput {
  provider: string;
  model: string;
  thinkingLevel?: string | null;
}

/**
 * Persist a new startup default: fresh read (fail closed on corrupt),
 * set ONLY the known keys (everything else preserved verbatim as parsed),
 * backup previous file, atomic rename. Returns backup path or null.
 */
export function writeConfiguredDefault(
  agentDir: string,
  input: WriteDefaultInput,
): { backup: string | null; settingsPath: string } {
  const settingsPath = piSettingsPath(agentDir);
  let current: Record<string, unknown> = {};
  if (existsSync(settingsPath)) {
    let raw: unknown;
    try {
      raw = readJsonFile<unknown>(settingsPath, undefined);
    } catch {
      throw new Error("settings_corrupt");
    }
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      throw new Error("settings_corrupt");
    }
    current = raw as Record<string, unknown>;
  }
  const next: Record<string, unknown> = { ...current };
  next["defaultProvider"] = input.provider;
  next["defaultModel"] = input.model;
  if (input.thinkingLevel !== undefined && input.thinkingLevel !== null) {
    next["defaultThinkingLevel"] = input.thinkingLevel;
  }
  const backup = backupFile(settingsPath);
  atomicWriteJson(settingsPath, next);
  return { backup, settingsPath };
}

/**
 * Resolve the pi binary: runtime-env.json PiBin (absolute, must exist),
 * else null (caller falls back to bare "pi" on PATH, like status does).
 */
export function resolvePiBin(appRoot: string | null): string | null {
  try {
    if (!appRoot) return null;
    const raw = readJsonFile<{ PiBin?: unknown }>(
      join(appRoot, "runtime-env.json"),
      {},
    );
    const bin = typeof raw.PiBin === "string" ? raw.PiBin : "";
    if (bin.length > 0 && existsSync(bin)) return bin;
    return null;
  } catch {
    return null;
  }
}
