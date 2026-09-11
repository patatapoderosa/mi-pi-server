/**
 * Module-schema tests: whitelist enforcement, types, ranges, merge.
 * Run: npm test  (node --test tests/)
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  BUILTIN_MODULES,
  isValidConfigFileName,
  isValidModuleName,
  validatePatch,
  type ModuleDefinition,
} from "../shared/modules.ts";

const DEF: ModuleDefinition = {
  name: "example-monitor",
  description: "test",
  configFile: "example-monitor.json",
  defaults: { enabled: true, intervalMinutes: 30 },
  schema: {
    enabled: { type: "boolean", description: "on/off" },
    intervalMinutes: {
      type: "integer",
      description: "minutes",
      min: 1,
      max: 1440,
    },
  },
};

describe("validatePatch", () => {
  it("accepts a valid patch and merges over current config", () => {
    const r = validatePatch(
      DEF,
      { enabled: false, intervalMinutes: 10 },
      { intervalMinutes: 45 },
    );
    assert.equal(r.ok, true);
    assert.deepEqual(r.merged, { enabled: false, intervalMinutes: 45 });
  });

  it("rejects unknown fields (no free-form model input)", () => {
    const r = validatePatch(
      DEF,
      {},
      { filePath: "/etc/passwd", intervalMinutes: 30 },
    );
    assert.equal(r.ok, false);
    assert.ok(r.errors.some((e) => e.startsWith("unknown_field:filePath")));
  });

  it("rejects shell-ish keys explicitly", () => {
    for (const evil of [
      "shellCommand",
      "command",
      "script",
      "processName",
      "run_script",
      "exec",
    ]) {
      const r = validatePatch(DEF, {}, { [evil]: "x" });
      assert.equal(r.ok, false, evil);
    }
  });

  it("rejects wrong types", () => {
    assert.equal(validatePatch(DEF, {}, { enabled: "yes" }).ok, false);
    assert.equal(validatePatch(DEF, {}, { intervalMinutes: 1.5 }).ok, false);
    assert.equal(validatePatch(DEF, {}, { intervalMinutes: "30" }).ok, false);
  });

  it("rejects out-of-range values", () => {
    assert.ok(
      validatePatch(DEF, {}, { intervalMinutes: 0 }).errors.some((e) =>
        e.endsWith("below_min"),
      ),
    );
    assert.ok(
      validatePatch(DEF, {}, { intervalMinutes: 2000 }).errors.some((e) =>
        e.endsWith("above_max"),
      ),
    );
  });

  it("rejects empty, oversized and non-object patches", () => {
    assert.equal(validatePatch(DEF, {}, {}).ok, false);
    assert.equal(validatePatch(DEF, {}, []).ok, false);
    assert.equal(validatePatch(DEF, {}, "str").ok, false);
    assert.equal(validatePatch(DEF, {}, null).ok, false);
    const big: Record<string, number> = {};
    for (let i = 0; i < 30; i++) big[`k${i}`] = i;
    assert.equal(validatePatch(DEF, {}, big).ok, false);
  });

  it("ignores unknown keys already sitting in the file (forward-safe reads)", () => {
    const r = validatePatch(
      DEF,
      { enabled: true, intervalMinutes: 5, legacy: "x" },
      { enabled: false },
    );
    assert.equal(r.ok, true);
    assert.deepEqual(r.merged, { enabled: false, intervalMinutes: 5 });
  });
});

describe("registries and names", () => {
  it("ships core + example-monitor builtins", () => {
    const names = BUILTIN_MODULES.map((m) => m.name).sort();
    assert.deepEqual(names, ["core", "example-monitor"]);
  });

  it("validates module and file names (no paths, no traversal)", () => {
    assert.equal(isValidModuleName("example-monitor"), true);
    assert.equal(isValidModuleName("../evil"), false);
    assert.equal(isValidModuleName("A B"), false);
    assert.equal(isValidConfigFileName("example-monitor.json"), true);
    assert.equal(isValidConfigFileName("../agent/settings.json"), false);
    assert.equal(isValidConfigFileName("a/b.json"), false);
    assert.equal(isValidConfigFileName("x"), false);
  });
});
