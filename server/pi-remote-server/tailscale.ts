/**
 * Tailscale helpers for the remote daemon.
 *
 * The daemon binds ONLY to the tailnet address (never 0.0.0.0): even with no
 * firewall rule at all, LAN hosts cannot reach a socket bound to 100.x.
 * A scoped Windows Firewall rule is added by the installer as a second layer.
 *
 * Uses only documented Tailscale CLI surface: `tailscale ip -4`.
 */
import { execFileSync } from "node:child_process";

export type ExecFn = (
  cmd: string,
  args: string[],
) => string;

/** Default executor: runs `tailscale ip -4`, returns stdout. Throws on failure. */
function defaultExec(cmd: string, args: string[]): string {
  return execFileSync(cmd, args, {
    encoding: "utf8",
    timeout: 15000,
    windowsHide: true,
  });
}

/**
 * True for IPv4 addresses inside 100.64.0.0/10 (the CGNAT range Tailscale
 * uses). Strict octet validation: rejects garbage from unexpected output.
 */
export function isTailscaleIpv4(ip: unknown): boolean {
  if (typeof ip !== "string") return false;
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip.trim());
  if (!m) return false;
  const octets = m.slice(1).map(Number);
  if (octets.some((n) => n < 0 || n > 255)) return false;
  const second = octets[1] as number;
  return octets[0] === 100 && second >= 64 && second <= 127;
}

/**
 * Our tailnet IPv4, or null when Tailscale is missing/offline.
 * Never throws: callers decide the fallback policy.
 */
export function getTailscaleIpv4(execFn: ExecFn = defaultExec): string | null {
  try {
    const out = execFn("tailscale", ["ip", "-4"]);
    const first = out
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l.length > 0);
    if (first && isTailscaleIpv4(first)) return first;
    return null;
  } catch {
    return null;
  }
}

export interface ListenResolution {
  host: string;
  /** Where the address came from. */
  source: "tailscale" | "override" | "loopback-fallback";
  tailscaleIp: string | null;
  warning?: string;
}

/**
 * Decide what to bind. Explicit override always wins (documented escape
 * hatch, e.g. PI_REMOTE_BIND=127.0.0.1 for local-only tests). Otherwise the
 * tailnet address. Loopback fallback keeps the daemon testable with a clear
 * warning when the tailnet is down — remote clients cannot reach it then.
 */
export function resolveListenAddress(opts: {
  bindOverride?: string;
  tailscaleIp: string | null;
}): ListenResolution {
  const override = opts.bindOverride?.trim();
  if (override && override.length > 0) {
    return {
      host: override,
      source: "override",
      tailscaleIp: opts.tailscaleIp,
    };
  }
  if (opts.tailscaleIp && isTailscaleIpv4(opts.tailscaleIp)) {
    return {
      host: opts.tailscaleIp,
      source: "tailscale",
      tailscaleIp: opts.tailscaleIp,
    };
  }
  return {
    host: "127.0.0.1",
    source: "loopback-fallback",
    tailscaleIp: opts.tailscaleIp,
    warning:
      "no Tailscale IPv4 found: bound to loopback, remote clients unreachable",
  };
}
