// OpenWhispr proxy: an OpenAI-compatible /v1/chat/completions endpoint on localhost that
// OpenWhispr's "Self-Hosted" cleanup provider can call. Each request is answered by Haiku
// through the official claude.exe, using the claude.ai login already on this machine.
// The Claude Profile Switcher starts and stops it, and tells it which account to use.
//
// Options: --capture <dir> saves every incoming request to <dir> (for a benchmark).
// Environment: OPENWHISPR_PROXY_PORT (8787), _MODEL (haiku), _EFFORT (low),
// _TIMEOUT_MS (25000), _CLAUDE_BIN (found automatically), _DATA (data folder).
import { createServer } from "node:http";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync, rmSync, watchFile } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { findClaudeBin } from "./claudeBin.mjs";
import { ClaudeRunner } from "./claude.mjs";
import { readAccount, accountInfo } from "./account.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
// Next to the switcher's settings, in a dot-folder the switcher never takes for a profile.
export const DATA_DIR = process.env.OPENWHISPR_PROXY_DATA ||
  join(process.env.LOCALAPPDATA || HERE, "ClaudeProfiles", ".openwhispr");
const PORT = Number(process.env.OPENWHISPR_PROXY_PORT || 8787);
const TIMEOUT_MS = Number(process.env.OPENWHISPR_PROXY_TIMEOUT_MS || 25000);
const DEFAULT_MODEL = process.env.OPENWHISPR_PROXY_MODEL || "haiku";
const EFFORT = process.env.OPENWHISPR_PROXY_EFFORT || "low";
const captureAt = process.argv.indexOf("--capture");
const CAPTURE_DIR = captureAt > 0 && process.argv[captureAt + 1] ? resolve(process.argv[captureAt + 1]) : null;
const CAPTURE = Boolean(CAPTURE_DIR);
const LOG_FILE = join(DATA_DIR, "proxy.log");
const PID_FILE = join(DATA_DIR, "proxy.pid");
// Last system prompt + model seen, so a restart can pre-warm before the first dictation.
// Holds OpenWhispr's cleanup prompt only, never dictated text.
const LAST_CONFIG_FILE = join(DATA_DIR, "last-config.json");
// Which Claude account to use; written by the Claude Profile Switcher (see src/account.mjs).
const ACCOUNT_FILE = join(DATA_DIR, "account.json");

mkdirSync(DATA_DIR, { recursive: true });
const WORK_DIR = join(DATA_DIR, "workdir"); // empty folder: no CLAUDE.md or project settings
mkdirSync(WORK_DIR, { recursive: true });

// Org admins can push settings to Claude Code (cached in ~/.claude/remote-settings.json) or
// install managed-settings.json. If any of them turns on OpenTelemetry content logging, the
// dictated text would reach the company's collector, so we look for it and warn.
const CONTENT_LOGGING_KEYS = /"(OTEL_LOG_USER_PROMPTS|OTEL_LOG_ASSISTANT_RESPONSES|OTEL_LOG_TOOL_DETAILS|CLAUDE_CODE_ENABLE_TELEMETRY)"/g;
// Remote settings are cached per account, inside that account's Claude Code folder.
function settingsFilesFor(configDir) {
  return [
    join(configDir || join(process.env.USERPROFILE || "", ".claude"), "remote-settings.json"),
    join(process.env.ProgramData || "C:\\ProgramData", "ClaudeCode", "managed-settings.json"),
    "C:\\Program Files\\ClaudeCode\\managed-settings.json",
  ];
}

export function contentLoggingSettings(files = settingsFilesFor(null)) {
  const found = [];
  for (const f of files) {
    let text;
    try { text = readFileSync(f, "utf8"); } catch { continue; }
    for (const m of text.matchAll(CONTENT_LOGGING_KEYS)) found.push(`${m[1]} in ${f}`);
  }
  return found;
}

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}`;
  console.log(line);
  try { appendFileSync(LOG_FILE, line + "\n"); } catch {}
}

// OpenAI message content can be a string or an array of parts.
function contentText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map((p) => (typeof p === "string" ? p : p?.text ?? "")).join("");
  return "";
}

export function splitMessages(messages = []) {
  const system = messages.filter((m) => m.role === "system").map((m) => contentText(m.content)).join("\n\n");
  const text = messages.filter((m) => m.role !== "system").map((m) => contentText(m.content)).join("\n\n");
  return { system, text };
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(body));
}

function sendError(res, status, message, type = "server_error") {
  send(res, status, { error: { message, type, code: null } });
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.setEncoding("utf8");
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      try { resolve(JSON.parse(raw || "{}")); } catch (e) { reject(e); }
    });
    req.on("error", reject);
  });
}

function capture(body) {
  try {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    const file = join(CAPTURE_DIR, `${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
    writeFileSync(file, JSON.stringify(body, null, 2));
    log(`captured request -> ${file}`);
  } catch (e) {
    log(`capture failed: ${e.message}`);
  }
}

async function chatCompletions(req, res, runner, account) {
  let body;
  try { body = await readJson(req); } catch { return sendError(res, 400, "invalid JSON", "invalid_request_error"); }
  if (CAPTURE) capture(body);

  const { system, text } = splitMessages(body.messages);
  if (!text.trim()) return sendError(res, 400, "no user content", "invalid_request_error");
  const model = body.model || DEFAULT_MODEL;
  try { writeFileSync(LAST_CONFIG_FILE, JSON.stringify({ system, model })); } catch {}

  const t0 = performance.now();
  let out;
  try {
    out = await runner.cleanup({ system, model, text, timeoutMs: TIMEOUT_MS });
  } catch (e) {
    log(`ERROR acct=${account.label} model=${model} in=${text.length}ch after ${Math.round(performance.now() - t0)}ms: ${e.message}`);
    return sendError(res, 502, e.message);
  }
  const ms = Math.round(performance.now() - t0);
  log(`ok acct=${account.label} model=${model} ${out.warm ? "warm" : "cold"} ${ms}ms in=${text.length}ch out=${out.text.length}ch`);

  const id = `chatcmpl-${randomUUID()}`;
  const created = Math.floor(Date.now() / 1000);
  const u = out.usage;
  const promptTokens = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
  const usage = { prompt_tokens: promptTokens, completion_tokens: u.output_tokens ?? 0, total_tokens: promptTokens + (u.output_tokens ?? 0) };

  if (body.stream) {
    // OpenWhispr's cleanup does not stream; answer in a single SSE chunk just in case.
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    const chunk = { id, object: "chat.completion.chunk", created, model, choices: [{ index: 0, delta: { role: "assistant", content: out.text }, finish_reason: "stop" }] };
    res.write(`data: ${JSON.stringify(chunk)}\n\n`);
    return res.end("data: [DONE]\n\n");
  }

  send(res, 200, {
    id, object: "chat.completion", created, model,
    choices: [{ index: 0, message: { role: "assistant", content: out.text }, finish_reason: "stop" }],
    usage,
  });
}

function main() {
  let bin;
  try { bin = findClaudeBin(); } catch (e) { log(`FATAL ${e.message}`); process.exit(1); }
  let account = readAccount(ACCOUNT_FILE);
  const runner = new ClaudeRunner({ bin, cwd: WORK_DIR, effort: EFFORT, configDir: account.configDir });
  const describe = (a) => {
    const info = accountInfo(a.configDir);
    return `${a.label} (${info.signedIn ? info.organization || "signed in" : "NOT SIGNED IN"})`;
  };
  const warnOrgLogging = () => {
    for (const hit of contentLoggingSettings(settingsFilesFor(account.configDir))) {
      log(`WARNING an organisation setting may log dictated content: ${hit}`);
    }
  };

  // Follow account.json without restarting: the switcher rewrites it when the account changes.
  watchFile(ACCOUNT_FILE, { interval: 1000 }, () => {
    const next = readAccount(ACCOUNT_FILE);
    if (next.configDir === account.configDir && next.label === account.label) return;
    account = next;
    runner.setAccount(account.configDir);
    log(`account -> ${describe(account)}`);
    warnOrgLogging();
  });

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, "http://localhost");
    const path = url.pathname.replace(/\/+$/, "");
    try {
      if (req.method === "POST" && path.endsWith("/chat/completions")) return await chatCompletions(req, res, runner, account);
      if (req.method === "GET" && path.endsWith("/models")) {
        return send(res, 200, { object: "list", data: [{ id: DEFAULT_MODEL, object: "model", owned_by: "anthropic" }] });
      }
      if (req.method === "GET" && path === "/health") {
        return send(res, 200, {
          ok: true, pid: process.pid, claude: bin,
          account: { label: account.label, configDir: account.configDir, ...accountInfo(account.configDir) },
          orgContentLogging: contentLoggingSettings(settingsFilesFor(account.configDir)),
        });
      }
      sendError(res, 404, `not found: ${req.method} ${url.pathname}`, "invalid_request_error");
    } catch (e) {
      log(`ERROR unhandled: ${e.stack || e.message}`);
      if (!res.headersSent) sendError(res, 500, e.message);
    }
  });

  server.on("error", (e) => {
    log(`FATAL ${e.code === "EADDRINUSE" ? `port ${PORT} already in use (proxy already running?)` : e.message}`);
    process.exit(1);
  });

  server.listen(PORT, "127.0.0.1", () => {
    writeFileSync(PID_FILE, String(process.pid));
    log(`account -> ${describe(account)}`);
    log(`listening on http://127.0.0.1:${PORT}/v1 model=${DEFAULT_MODEL} effort=${EFFORT} timeout=${TIMEOUT_MS}ms capture=${CAPTURE} claude=${bin}`);
    warnOrgLogging();
    try {
      const last = JSON.parse(readFileSync(LAST_CONFIG_FILE, "utf8"));
      runner.prewarm(last.system, last.model);
      log(`pre-warmed with last prompt (model=${last.model})`);
    } catch {}
  });

  const shutdown = () => {
    runner.close();
    try { rmSync(PID_FILE); } catch {}
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main();
