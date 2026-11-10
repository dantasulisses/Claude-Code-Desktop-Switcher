// Runs one cleanup through the official claude.exe, logged in with the claude.ai account.
//
// Measured on this machine (see README): spawning `claude -p` per request ~3.1s, a
// pre-warmed process ~1.6s. So we keep ONE idle process already started with the
// current system prompt/model, use it for a single request, kill it and warm the next.
// Single use means no conversation history leaks between dictations.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { claudeEnv } from "./claudeBin.mjs";

const MAX_IDLE_MS = 15 * 60 * 1000; // recycle the warm process so it never goes stale

function flagsFor({ system, model, effort }) {
  return [
    "-p", "--model", model, "--effort", effort,
    "--tools", "", "--strict-mcp-config", "--setting-sources", "",
    "--disable-slash-commands", "--no-session-persistence",
    "--system-prompt", system,
    "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
  ];
}

class Worker {
  constructor(bin, cwd, config) {
    this.config = config;
    this.key = JSON.stringify(config);
    this.bornAt = Date.now();
    this.stderr = "";
    this.proc = spawn(bin, flagsFor(config), { cwd, env: claudeEnv(config.configDir), windowsHide: true });
    this.exited = new Promise((resolve) => this.proc.on("close", resolve));
    this.proc.on("error", () => {});
    this.proc.stderr.on("data", (d) => (this.stderr = (this.stderr + d).slice(-2000)));
    this.result = new Promise((resolve) => {
      createInterface({ input: this.proc.stdout }).on("line", (line) => {
        let ev;
        try { ev = JSON.parse(line); } catch { return; }
        if (ev.type === "result") resolve(ev);
      });
    });
    this.dead = false;
    this.exited.then(() => (this.dead = true));
  }

  kill() {
    if (!this.dead) this.proc.kill();
  }

  async run(text, timeoutMs) {
    this.proc.stdin.write(JSON.stringify({ type: "user", message: { role: "user", content: text } }) + "\n");
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`timeout after ${timeoutMs}ms`)), timeoutMs);
    });
    const exitedEarly = this.exited.then((code) => {
      throw new Error(`claude.exe exited (${code}) before answering: ${this.stderr.trim()}`);
    });
    try {
      const ev = await Promise.race([this.result, timeout, exitedEarly]);
      if (ev.is_error) throw new Error(`claude error (${ev.subtype}): ${ev.result ?? ""}`);
      return { text: ev.result ?? "", usage: ev.usage ?? {} };
    } finally {
      clearTimeout(timer);
      this.kill();
    }
  }
}

export class ClaudeRunner {
  constructor({ bin, cwd, effort, configDir = null }) {
    this.bin = bin;
    this.cwd = cwd;
    this.effort = effort;
    this.configDir = configDir; // which Claude Code login folder to use; null = the default ~/.claude
    this.warm = null;
    this.recycler = setInterval(() => {
      const w = this.warm;
      if (w && (w.dead || Date.now() - w.bornAt >= MAX_IDLE_MS)) this.prewarm(w.config.system, w.config.model);
    }, 60 * 1000);
    this.recycler.unref();
  }

  #spawn(config) {
    return new Worker(this.bin, this.cwd, config);
  }

  // Start a warm process for the given prompt/model so the next request is fast.
  prewarm(system, model) {
    this.warm?.kill();
    this.warm = this.#spawn({ system, model, effort: this.effort, configDir: this.configDir });
  }

  // Switch the account (Claude Code config folder) used from the next request on.
  // The warm process belongs to the old account, so it is replaced right away.
  setAccount(configDir) {
    if ((configDir ?? null) === this.configDir) return;
    this.configDir = configDir ?? null;
    const w = this.warm;
    if (w) this.prewarm(w.config.system, w.config.model);
  }

  #take(config) {
    const key = JSON.stringify(config);
    const w = this.warm;
    this.warm = null;
    if (w && !w.dead && w.key === key && Date.now() - w.bornAt < MAX_IDLE_MS) return { worker: w, warm: true };
    w?.kill();
    return { worker: this.#spawn(config), warm: false };
  }

  async cleanup({ system, model, text, timeoutMs }) {
    const config = { system, model, effort: this.effort, configDir: this.configDir };
    const { worker, warm } = this.#take(config);
    try {
      const out = await worker.run(text, timeoutMs);
      return { ...out, warm };
    } finally {
      // Warm the replacement only after this answer is out: starting it in parallel
      // slowed every other request (measured ~1.6s vs ~3.3s alternating).
      if (!this.warm) this.warm = this.#spawn(config);
    }
  }

  close() {
    clearInterval(this.recycler);
    this.warm?.kill();
    this.warm = null;
  }
}
