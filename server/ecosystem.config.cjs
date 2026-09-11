/**
 * ecosystem.config.cjs — PM2 process file for the 24/7 Pi node.
 *
 * All paths derive from the agent dir (~/.pi/agent or $PI_CODING_AGENT_DIR),
 * never from the shell's cwd, so `pm2 resurrect` works after reboot.
 * Add future services as new entries in `apps` — same shape, own logs.
 */
const { homedir } = require("node:os");
const { join } = require("node:path");

const AGENT_DIR =
    process.env["PI_CODING_AGENT_DIR"] &&
    process.env["PI_CODING_AGENT_DIR"].trim().length > 0
        ? process.env["PI_CODING_AGENT_DIR"]
        : join(homedir(), ".pi", "agent");

// Repo checkout location. The Linux setup symlinks the extension dirs, but the
// daemon + ecosystem live wherever you cloned this repo; override with
// PI_REMOTE_SYSTEM_DIR when it differs from the default.
const SYSTEM_DIR =
    process.env["PI_REMOTE_SYSTEM_DIR"] &&
    process.env["PI_REMOTE_SYSTEM_DIR"].trim().length > 0
        ? process.env["PI_REMOTE_SYSTEM_DIR"]
        : join(homedir(), "pi-remote-system");

const LOG_DIR = join(AGENT_DIR, "logs");

module.exports = {
    apps: [
        {
            name: "pi-server",
            script: join(SYSTEM_DIR, "server", "pi-daemon.mjs"),
            interpreter: "node",
            cwd: SYSTEM_DIR,
            autorestart: true,
            restart_delay: 5000,
            max_memory_restart: "1G",
            kill_timeout: 20000,
            log_date_format: "YYYY-MM-DD HH:mm:ss Z",
            out_file: join(LOG_DIR, "pi-server-out.log"),
            err_file: join(LOG_DIR, "pi-server-err.log"),
            merge_logs: true,
            env: {
                NODE_ENV: "production",
                PI_REMOTE_SYSTEM_DIR: SYSTEM_DIR,
                PI_CODING_AGENT_DIR: AGENT_DIR,
            },
        },
    ],
};
