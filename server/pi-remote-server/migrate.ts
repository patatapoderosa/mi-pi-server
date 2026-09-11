/**
 * One-way migration from the legacy Telegram-transport config.
 *
 * Old world: remote-auth.json { allowedControlBotId, controlChatId, ... }
 * New world: remote-server.json { port, bindHost?, maxSkewSeconds,
 *   allowedServices } + HMAC untouched in secrets/remote-hmac.
 *
 * Behavior:
 * - no remote-auth.json -> nothing to do ({ migrated: false })
 * - otherwise: back up the legacy file, write remote-server.json ONLY if it
 *   does not exist yet (never overwrite a newer config), then RENAME the
 *   legacy file to *.bak-<ts>.migrated so dead ControlBot fields cannot
 *   confuse anyone later. The HMAC secret file is never touched.
 */
import {
  chmodSync,
  existsSync,
  mkdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { backupFile, readJsonFile } from "../../shared/store.ts";
import { DEFAULT_REMOTE_PORT } from "../../shared/protocol.ts";

export interface MigrationResult {
  migrated: boolean;
  backupPath: string | null;
  notes: string[];
}

interface LegacyAuth {
  allowedControlBotId?: unknown;
  controlChatId?: unknown;
  maxSkewSeconds?: unknown;
  allowedServices?: unknown;
}

function clampSkew(v: unknown): number {
  if (typeof v !== "number" || !Number.isFinite(v)) return 300;
  return Math.min(3600, Math.max(30, Math.floor(v)));
}

function stringList(v: unknown): string[] {
  if (!Array.isArray(v)) return ["pi-server"];
  const out = v.filter((s): s is string => typeof s === "string");
  return out.length > 0 ? out : ["pi-server"];
}

function validPort(v: unknown): number {
  if (
    typeof v !== "number" ||
    !Number.isInteger(v) ||
    v < 1 ||
    v > 65535
  ) {
    return DEFAULT_REMOTE_PORT;
  }
  return v;
}

export function migrateLegacyConfig(agentDir: string): MigrationResult {
  const notes: string[] = [];
  const legacyPath = join(agentDir, "remote-auth.json");
  const newPath = join(agentDir, "remote-server.json");
  if (!existsSync(legacyPath)) {
    return { migrated: false, backupPath: null, notes };
  }
  const legacy = readJsonFile<LegacyAuth>(legacyPath, {});
  const backupPath = backupFile(legacyPath);
  notes.push(
    `legacy remote-auth.json backed up to ${backupPath ?? "(backup failed)"}`,
  );
  if ("allowedControlBotId" in legacy || "controlChatId" in legacy) {
    notes.push(
      "dropped ControlBot fields (allowedControlBotId, controlChatId): " +
        "Telegram transport removed, HMAC secret preserved untouched",
    );
  }
  if (!existsSync(newPath)) {
    mkdirSync(agentDir, { recursive: true });
    writeFileSync(
      newPath,
      JSON.stringify(
        {
          port: DEFAULT_REMOTE_PORT,
          maxSkewSeconds: clampSkew(legacy.maxSkewSeconds),
          allowedServices: stringList(legacy.allowedServices),
        },
        null,
        2,
      ) + "\n",
      { mode: 0o600 },
    );
    try {
      chmodSync(newPath, 0o600);
    } catch {
      // ignore on platforms without POSIX modes
    }
    notes.push("remote-server.json created from legacy values");
  } else {
    notes.push("remote-server.json already exists: kept, legacy values ignored");
  }
  // Least surprise wins over archaeology: move the legacy file away so the
  // dead ControlBot fields cannot be mistaken for live config.
  try {
    rmSync(legacyPath);
    notes.push("legacy remote-auth.json removed (backup kept)");
  } catch {
    notes.push("WARNING: could not remove legacy remote-auth.json");
  }
  return { migrated: true, backupPath, notes };
}

export { clampSkew, stringList, validPort };
