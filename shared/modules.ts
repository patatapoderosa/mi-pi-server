/**
 * Module registry model: every remotely-configurable module declares
 * - a fixed config FILE NAME inside server-config/ (never an arbitrary path),
 * - defaults,
 * - a field schema (type + range/enum constraints),
 * - optional service names it may query via service_control.
 *
 * The model can only send { module, patch } with KNOWN fields; unknown
 * fields, wrong types and out-of-range values are rejected before any write.
 */
export type FieldType = "boolean" | "integer" | "number" | "string";
export type PatchValue = string | number | boolean;

export interface FieldSchema {
  type: FieldType;
  description: string;
  min?: number;
  max?: number;
  enum?: Array<string | number>;
  /** Max length for strings. */
  maxLength?: number;
}

export interface ModuleDefinition {
  /** Stable id, e.g. "example-monitor". Lowercase letters, digits, dashes. */
  name: string;
  description: string;
  /** Fixed file name only, e.g. "example-monitor.json". No slashes allowed. */
  configFile: string;
  defaults: Record<string, PatchValue>;
  schema: Record<string, FieldSchema>;
  /** Services this module is allowed to inspect via service_control. */
  services?: string[];
}

export function isValidModuleName(name: unknown): name is string {
  return typeof name === "string" && /^[a-z0-9][a-z0-9-]{0,47}$/.test(name);
}

export function isValidConfigFileName(name: unknown): boolean {
  return (
    typeof name === "string" &&
    /^[a-z0-9][a-z0-9_.-]{0,63}\.json$/.test(name) &&
    !name.includes("/") &&
    !name.includes("\\")
  );
}

export interface ValidationResult {
  ok: boolean;
  errors: string[];
  /** Full merged config (current + sanitized patch). Present only when ok. */
  merged?: Record<string, PatchValue>;
}

export function validatePatch(
  def: ModuleDefinition,
  current: Record<string, unknown>,
  patch: unknown,
): ValidationResult {
  const errors: string[] = [];
  if (typeof patch !== "object" || patch === null || Array.isArray(patch)) {
    return { ok: false, errors: ["patch_must_be_object"] };
  }
  const entries = Object.entries(patch as Record<string, unknown>);
  if (entries.length === 0) return { ok: false, errors: ["patch_empty"] };
  if (entries.length > 25) return { ok: false, errors: ["patch_too_large"] };

  const merged: Record<string, PatchValue> = {};
  for (const [key, value] of Object.entries(def.defaults)) merged[key] = value;
  for (const [key, value] of Object.entries(current)) {
    if (
      key in def.schema &&
      (typeof value === "string" ||
        typeof value === "number" ||
        typeof value === "boolean")
    ) {
      merged[key] = value;
    }
  }

  for (const [key, raw] of entries) {
    const field = def.schema[key];
    if (!field) {
      errors.push(`unknown_field:${key}`);
      continue;
    }
    const err = checkField(key, raw, field);
    if (err) {
      errors.push(err);
      continue;
    }
    merged[key] = raw as PatchValue;
  }
  if (errors.length > 0) return { ok: false, errors };
  return { ok: true, errors: [], merged };
}

function checkField(
  key: string,
  raw: unknown,
  field: FieldSchema,
): string | null {
  switch (field.type) {
    case "boolean":
      return typeof raw === "boolean" ? null : `${key}_must_be_boolean`;
    case "string": {
      if (typeof raw !== "string") return `${key}_must_be_string`;
      if (field.maxLength !== undefined && raw.length > field.maxLength)
        return `${key}_too_long`;
      if (field.enum !== undefined && !field.enum.includes(raw))
        return `${key}_not_allowed`;
      return null;
    }
    case "integer": {
      if (typeof raw !== "number" || !Number.isInteger(raw))
        return `${key}_must_be_integer`;
      if (field.min !== undefined && raw < field.min) return `${key}_below_min`;
      if (field.max !== undefined && raw > field.max) return `${key}_above_max`;
      if (field.enum !== undefined && !field.enum.includes(raw))
        return `${key}_not_allowed`;
      return null;
    }
    case "number": {
      if (typeof raw !== "number" || !Number.isFinite(raw))
        return `${key}_must_be_number`;
      if (field.min !== undefined && raw < field.min) return `${key}_below_min`;
      if (field.max !== undefined && raw > field.max) return `${key}_above_max`;
      return null;
    }
    default:
      return `${key}_unknown_type`;
  }
}

/** Built-in modules shipped with pi-remote-config. */
export const BUILTIN_MODULES: ModuleDefinition[] = [
  {
    name: "core",
    description:
      "Server node core flags (maintenance mode, remote-control enable switch).",
    configFile: "core.json",
    defaults: { maintenanceMode: false, remoteControlEnabled: true },
    schema: {
      maintenanceMode: {
        type: "boolean",
        description:
          "When true, set_config ops are refused (status/ping still answer).",
      },
      remoteControlEnabled: {
        type: "boolean",
        description: "Master switch for remote set_config/service ops.",
      },
    },
  },
  {
    name: "example-monitor",
    description:
      "Template periodic module. Copy this definition to add a real module.",
    configFile: "example-monitor.json",
    defaults: { enabled: true, intervalMinutes: 30 },
    schema: {
      enabled: { type: "boolean", description: "Whether the monitor runs." },
      intervalMinutes: {
        type: "integer",
        description: "Run interval in minutes.",
        min: 1,
        max: 1440,
      },
    },
    services: ["example-monitor"],
  },
];
