/**
 * Disk helpers: agent-dir resolution, atomic JSON writes, backups,
 * and the persistent anti-replay store.
 *
 * All writes are atomic (tmp file + rename) and config files get a
 * timestamped .bak copy before being overwritten.
 */
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export function resolveAgentDir(): string {
  const override = process.env["PI_CODING_AGENT_DIR"];
  if (override && override.trim().length > 0) return override;
  return join(homedir(), ".pi", "agent");
}

export function ensureDir(path: string, mode = 0o700): void {
  mkdirSync(path, { recursive: true, mode });
  try {
    chmodSync(path, mode);
  } catch {
    // Best effort (e.g. Windows ACLs are handled by the .ps1 setup).
  }
}

export function readJsonFile<T>(path: string, fallback: T): T {
  try {
    if (!existsSync(path)) return fallback;
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return fallback;
  }
}

/** Atomic write: tmp in same dir + rename. Mode defaults to 0600 (secrets-safe). */
export function atomicWriteJson(
  path: string,
  value: unknown,
  mode = 0o600,
): void {
  ensureDir(dirname(path), 0o700);
  const tmp = `${path}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", { mode });
  try {
    chmodSync(tmp, mode);
  } catch {
    // ignore on platforms without POSIX modes
  }
  renameSync(tmp, path);
}

/** Copy path -> path.bak-<UTC timestamp> when it exists. Returns backup path or null. */
export function backupFile(path: string): string | null {
  try {
    if (!existsSync(path) || !statSync(path).isFile()) return null;
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const bak = `${path}.bak-${stamp}`;
    copyFileSync(path, bak);
    return bak;
  } catch {
    return null;
  }
}

export interface NonceEntry {
  n: string;
  ts: number;
}

export interface RemoteState {
  nonces: NonceEntry[];
  lastRemoteUpdate?: {
    at: number;
    op: string;
    module?: string;
    ok: boolean;
    error?: string;
  };
  lastError?: { at: number; where: string; message: string };
}

const MAX_NONCES = 500;

export class ReplayStore {
  private state: RemoteState;
  private filePath: string;
  private windowSeconds: number;

  constructor(filePath: string, windowSeconds: number) {
    this.filePath = filePath;
    this.windowSeconds = windowSeconds;
    this.state = readJsonFile<RemoteState>(filePath, { nonces: [] });
    // Disk state is untrusted: drop malformed nonce entries so downstream
    // property accesses can never throw on corrupt files.
    if (!Array.isArray(this.state.nonces)) {
      this.state.nonces = [];
    } else {
      this.state.nonces = this.state.nonces.filter(
        (e) => e !== null && typeof e === "object" && typeof e.n === "string" && typeof e.ts === "number",
      );
    }
  }

  /** True when the nonce was seen inside the replay window. Cleans expired entries. */
  has(nonce: string, nowSec: number): boolean {
    // Invalid input can never throw: fail closed (treat as already seen).
    if (typeof nonce !== "string" || typeof nowSec !== "number" || !Number.isFinite(nowSec)) {
      return true;
    }
    try {
      this.prune(nowSec);
      return this.seen(nonce);
    } catch {
      return true; // fail closed: storage error => treat as already seen
    }
  }

  /** Replay lookup that can never throw: fail closed (treat as seen) on corrupt state. */
  private seen(nonce: string): boolean {
    try {
      return this.state.nonces.some((e) => e !== null && typeof e === "object" && e.n === nonce);
    } catch {
      return true;
    }
  }

  add(nonce: string, tsSec: number, nowSec: number): void {
    this.prune(nowSec);
    if (!this.seen(nonce)) {
      this.state.nonces.push({ n: nonce, ts: tsSec });
    }
    while (this.state.nonces.length > MAX_NONCES) this.state.nonces.shift();
    this.save();
  }

  recordUpdate(entry: NonNullable<RemoteState["lastRemoteUpdate"]>): void {
    this.state.lastRemoteUpdate = entry;
    this.save();
  }

  recordError(where: string, message: string): void {
    this.state.lastError = {
      at: Math.floor(Date.now() / 1000),
      where,
      message: message.slice(0, 300),
    };
    try {
      this.save();
    } catch {
      // error reporting must never crash the host
    }
  }

  snapshot(): RemoteState {
    try {
      return structuredClone(this.state);
    } catch {
      // Defensive fallback: state is always plain JSON data, so this
      // path is unreachable in practice. Manual deep copy instead.
      return {
        nonces: this.state.nonces.map((e) => ({ n: e.n, ts: e.ts })),
        ...(this.state.lastRemoteUpdate
          ? { lastRemoteUpdate: { ...this.state.lastRemoteUpdate } }
          : {}),
        ...(this.state.lastError ? { lastError: { ...this.state.lastError } } : {}),
      };
    }
  }

  private prune(nowSec: number): void {
    try {
      const cutoff = nowSec - this.windowSeconds;
      if (!Array.isArray(this.state.nonces)) {
        this.state.nonces = [];
        return;
      }
      this.state.nonces = this.state.nonces.filter(
        (e) => e !== null && typeof e === "object" && typeof e.ts === "number" && e.ts >= cutoff,
      );
    } catch {
      // Leave state untouched: dropping nonces on error would weaken replay protection.
    }
  }

  private save(): void {
    atomicWriteJson(this.filePath, this.state, 0o600);
  }
}
