/**
 * Remote Model Management unit tests: table parsing, selection
 * normalization (mirroring Pi 0.85.1 resolveCliModel), settings.json
 * read/write with backup, thinking levels, PiBin resolution.
 * Run: npm test  (node --test tests/)
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  THINKING_LEVELS,
  isValidThinkingLevel,
  normalizeSelection,
  parseListModelsTable,
  piSettingsPath,
  readConfiguredDefault,
  resolvePiBin,
  writeConfiguredDefault,
  type PiModelInfo,
} from "../shared/pi-model.ts";

function mkModel(
  provider: string,
  id: string,
  extra?: Partial<PiModelInfo>,
): PiModelInfo {
  return {
    provider,
    id,
    name: null,
    thinking: false,
    images: false,
    context: "128K",
    maxOut: "4K",
    ...extra,
  };
}

// Real `pi --list-models` output shape (verified on 0.85.1 with a probe
// agent dir + dummy provider; CRLF variant included on purpose).
const REAL_TABLE =
  "provider  model         context  max-out  thinking  images\r\n" +
  "fakeprov  fake-model-a  128K     16.4K    yes       no    \r\n" +
  "fakeprov  fake-model-b  128K     16.4K    no        no    \r\n";

describe("parseListModelsTable", () => {
  it("parses real CLI output incl. CRLF + trailing spaces", () => {
    const r = parseListModelsTable(REAL_TABLE);
    assert.equal(r.ok, true);
    if (!r.ok) return;
    assert.equal(r.models.length, 2);
    assert.deepEqual(r.models[0], {
      provider: "fakeprov",
      id: "fake-model-a",
      name: null,
      thinking: true,
      images: false,
      context: "128K",
      maxOut: "16.4K",
    });
    assert.equal(r.models[1].thinking, false);
  });

  it("empty output means no models (not an error)", () => {
    assert.deepEqual(parseListModelsTable(""), { ok: true, models: [] });
    assert.deepEqual(parseListModelsTable("  \n\n"), {
      ok: true,
      models: [],
    });
  });

  it("rejects wrong header (never guess)", () => {
    const r = parseListModelsTable("foo  bar\nx  y  z  w  v  u\n");
    assert.equal(r.ok, false);
    if (!r.ok) assert.equal(r.error, "table_header_mismatch");
  });

  it("rejects malformed rows and bad yes/no", () => {
    const head =
      "provider  model  context  max-out  thinking  images\n";
    assert.equal(
      parseListModelsTable(head + "a  b  c  d  yes\n").ok,
      false,
    );
    const bad = parseListModelsTable(head + "a  b  c  d  maybe  no\n");
    assert.equal(bad.ok, false);
    if (!bad.ok) assert.equal(bad.error, "table_row_mismatch");
  });

  it("accepts YES/NO case-insensitively", () => {
    const r = parseListModelsTable(
      "provider  model  context  max-out  thinking  images\n" +
        "p  m  1K  1K  YES  No\n",
    );
    assert.equal(r.ok, true);
    if (!r.ok) return;
    assert.equal(r.models[0].thinking, true);
    assert.equal(r.models[0].images, false);
  });
});

const CATALOG = [
  mkModel("anthropic", "claude-opus-4-8"),
  mkModel("openai", "gpt-5.5"),
  mkModel("openai", "gpt-5.4"),
];

describe("normalizeSelection", () => {
  it("exact id within provider", () => {
    assert.deepEqual(
      normalizeSelection({ provider: "openai", model: "gpt-5.5" }, CATALOG),
      { ok: true, provider: "openai", model: "gpt-5.5" },
    );
  });

  it("provider lookup is case-insensitive, canonical spelling kept", () => {
    const r = normalizeSelection(
      { provider: "OpenAI", model: "gpt-5.5" },
      CATALOG,
    );
    assert.deepEqual(r, { ok: true, provider: "openai", model: "gpt-5.5" });
  });

  it("tolerates provider/ prefix duplication", () => {
    assert.deepEqual(
      normalizeSelection(
        { provider: "openai", model: "openai/gpt-5.5" },
        CATALOG,
      ),
      { ok: true, provider: "openai", model: "gpt-5.5" },
    );
  });

  it("infers provider from provider/model form", () => {
    assert.deepEqual(
      normalizeSelection({ model: "anthropic/claude-opus-4-8" }, CATALOG),
      { ok: true, provider: "anthropic", model: "claude-opus-4-8" },
    );
  });

  it("rejects unknown provider with available list", () => {
    const r = normalizeSelection(
      { provider: "nope", model: "gpt-5.5" },
      CATALOG,
    );
    assert.equal(r.ok, false);
    if (!r.ok) assert.match(r.error, /^unknown_provider:nope/);
  });

  it("rejects unknown model", () => {
    const r = normalizeSelection(
      { provider: "openai", model: "gpt-99" },
      CATALOG,
    );
    assert.equal(r.ok, false);
    if (!r.ok) assert.match(r.error, /^model_not_found:gpt-99/);
  });

  it("rejects ambiguous bare id, prefers sole authed like Pi", () => {
    const dup = [
      ...CATALOG,
      mkModel("openrouter", "gpt-5.5"),
    ];
    const amb = normalizeSelection({ model: "gpt-5.5" }, dup);
    assert.equal(amb.ok, false);
    if (!amb.ok) assert.match(amb.error, /^model_ambiguous/);
    const resolved = normalizeSelection({ model: "gpt-5.5" }, dup, [
      "openrouter",
    ]);
    assert.deepEqual(resolved, {
      ok: true,
      provider: "openrouter",
      model: "gpt-5.5",
    });
  });

  it("requires a model and a non-empty catalog", () => {
    assert.deepEqual(normalizeSelection({ provider: "openai" }, CATALOG), {
      ok: false,
      error: "model_required",
    });
    assert.deepEqual(
      normalizeSelection({ provider: "openai", model: "x" }, []),
      { ok: false, error: "no_models_available" },
    );
  });
});

describe("thinking levels (Pi 0.85.1 core/defaults.js)", () => {
  it("matches the real enum incl. default medium", () => {
    assert.deepEqual([...THINKING_LEVELS], [
      "off",
      "minimal",
      "low",
      "medium",
      "high",
      "xhigh",
      "max",
    ]);
    assert.equal(isValidThinkingLevel("medium"), true);
    assert.equal(isValidThinkingLevel("ultra"), false);
    assert.equal(isValidThinkingLevel(""), false);
    assert.equal(isValidThinkingLevel(undefined), false);
  });
});

describe("settings.json read/write (server agentDir only)", () => {
  it("missing file means unset (never ~/.pi)", () => {
    const dir = mkdtempSync(join(tmpdir(), "pimodel-"));
    try {
      const got = readConfiguredDefault(dir);
      assert.equal(got.provider, null);
      assert.equal(got.model, null);
      assert.equal(got.source, "unset");
      assert.equal(got.settingsPath, join(dir, "settings.json"));
      assert.equal(piSettingsPath(dir), join(dir, "settings.json"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("round-trips defaults and preserves unknown fields + backup", () => {
    const dir = mkdtempSync(join(tmpdir(), "pimodel-"));
    try {
      writeFileSync(
        join(dir, "settings.json"),
        JSON.stringify(
          { theme: "dark", retry: { maxRetries: 3 }, defaultModel: "old" },
          null,
          2,
        ),
      );
      const w = writeConfiguredDefault(dir, {
        provider: "anthropic",
        model: "claude-opus-4-8",
        thinkingLevel: "high",
      });
      assert.ok(w.backup !== null);
      const raw = JSON.parse(readFileSync(join(dir, "settings.json"), "utf8")) as Record<
        string,
        unknown
      >;
      assert.equal(raw["defaultProvider"], "anthropic");
      assert.equal(raw["defaultModel"], "claude-opus-4-8");
      assert.equal(raw["defaultThinkingLevel"], "high");
      assert.equal(raw["theme"], "dark");
      assert.deepEqual(raw["retry"], { maxRetries: 3 });
      const back = JSON.parse(readFileSync(w.backup as string, "utf8")) as Record<
        string,
        unknown
      >;
      assert.equal(back["defaultModel"], "old");
      const got = readConfiguredDefault(dir);
      assert.equal(got.provider, "anthropic");
      assert.equal(got.model, "claude-opus-4-8");
      assert.equal(got.thinkingLevel, "high");
      assert.equal(got.source, "settings.json");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("omitted thinkingLevel leaves the key untouched", () => {
    const dir = mkdtempSync(join(tmpdir(), "pimodel-"));
    try {
      writeFileSync(
        join(dir, "settings.json"),
        JSON.stringify({ defaultThinkingLevel: "low" }),
      );
      writeConfiguredDefault(dir, { provider: "p", model: "m" });
      const raw = JSON.parse(readFileSync(join(dir, "settings.json"), "utf8")) as Record<
        string,
        unknown
      >;
      assert.equal(raw["defaultThinkingLevel"], "low");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("refuses corrupt files (fail closed, like Pi)", () => {
    const dir = mkdtempSync(join(tmpdir(), "pimodel-"));
    try {
      writeFileSync(join(dir, "settings.json"), "{oops");
      assert.throws(() => readConfiguredDefault(dir), /settings_corrupt/);
      assert.throws(
        () => writeConfiguredDefault(dir, { provider: "p", model: "m" }),
        /settings_corrupt/,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("resolvePiBin", () => {
  it("prefers validated runtime-env.json PiBin, else null", () => {
    const dir = mkdtempSync(join(tmpdir(), "pimodel-"));
    try {
      assert.equal(resolvePiBin(dir), null);
      assert.equal(resolvePiBin(null), null);
      writeFileSync(
        join(dir, "runtime-env.json"),
        JSON.stringify({ PiBin: join(dir, "nope.exe") }),
      );
      assert.equal(resolvePiBin(dir), null);
      const fake = join(dir, "pi.exe");
      writeFileSync(fake, "x");
      writeFileSync(join(dir, "runtime-env.json"), JSON.stringify({ PiBin: fake }));
      assert.equal(resolvePiBin(dir), fake);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
