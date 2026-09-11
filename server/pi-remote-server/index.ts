/**
 * pi-remote-server entry point: authenticated HTTP API for Mac -> server
 * control over the tailnet. Run directly with Node (type-stripping):
 *   node server/pi-remote-server/index.ts
 *
 * Standalone process on purpose: it must keep answering even when Pi or
 * pi-telegram is down (fault isolation; separate Task Scheduler task).
 *
 * Boot order: agent dir -> legacy migration -> config -> HMAC (fatal if
 * missing) -> tailnet bind resolution -> listen -> graceful shutdown.
 */
import { dirname, join } from "node:path";
import { createRemoteServer, loadRemoteHmac, loadRemoteServerConfig, readAppVersion } from "./server.ts";
import { getTailscaleIpv4, resolveListenAddress } from "./tailscale.ts";
import { migrateLegacyConfig } from "./migrate.ts";
import { ensureDir, resolveAgentDir } from "../../shared/store.ts";

const LOG = "[pi-remote-server]";

function log(msg: string): void {
  process.stdout.write(`${new Date().toISOString()} ${LOG} ${msg}\n`);
}

function fail(msg: string): never {
  process.stderr.write(`${new Date().toISOString()} ${LOG}:err ${msg}\n`);
  process.exit(1);
}

async function main(): Promise<void> {
  const agentDir = resolveAgentDir();
  ensureDir(agentDir, 0o700);

  const migration = migrateLegacyConfig(agentDir);
  for (const note of migration.notes) log(`migrate: ${note}`);

  const config = loadRemoteServerConfig(agentDir);

  const hmac = loadRemoteHmac(agentDir);
  if (!hmac) {
    fail(
      `no HMAC secret at ${join(agentDir, "secrets", "remote-hmac")}; refusing to run without auth`,
    );
  }

  const envBind = process.env["PI_REMOTE_BIND"];
  const bindOverride =
    (envBind && envBind.trim().length > 0 ? envBind : config.bindHost) ??
    undefined;
  const tailscaleIp = getTailscaleIpv4();
  const listen = resolveListenAddress({ bindOverride, tailscaleIp });
  if (listen.warning) log(`WARN: ${listen.warning}`);
  log(
    `bind ${listen.host}:${config.port} (source=${listen.source}` +
      (listen.tailscaleIp ? `, tailscale=${listen.tailscaleIp}` : "") +
      `)`,
  );

  const { server } = createRemoteServer({
    agentDir,
    hmac,
    config,
    bindHost: listen.host,
    version: readAppVersion(join(dirname(import.meta.dirname), "..", "..")),
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.port, listen.host, () => {
      server.removeListener("error", reject);
      resolve();
    });
  });
  log(`listening on http://${listen.host}:${config.port}`);

  let shuttingDown = false;
  const shutdown = (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log(`received ${signal}, closing`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

process.on("uncaughtException", (err) => {
  process.stderr.write(
    `${new Date().toISOString()} ${LOG}:err uncaught: ${err instanceof Error ? err.message : "unknown"} — exiting for supervisor restart\n`,
  );
  process.exit(1);
});

main().catch((err) => {
  fail(err instanceof Error ? err.message : "boot failed");
});
