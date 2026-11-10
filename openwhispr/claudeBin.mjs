// Locates the official claude.exe. The copy bundled with the Claude desktop app
// lives in a versioned folder that changes on every update, so we search for it.
import { existsSync, readdirSync, statSync } from "node:fs";
import { join, delimiter } from "node:path";

function newestClaudeIn(root) {
  // Layout: <root>\claude-code\<version>\<hash>\claude.exe
  const base = join(root, "claude-code");
  if (!existsSync(base)) return [];
  const found = [];
  for (const version of readdirSync(base)) {
    const versionDir = join(base, version);
    if (!statSync(versionDir).isDirectory()) continue;
    for (const hash of readdirSync(versionDir)) {
      const exe = join(versionDir, hash, "claude.exe");
      if (existsSync(exe)) found.push({ exe, mtime: statSync(exe).mtimeMs });
    }
  }
  return found;
}

function onPath() {
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    for (const name of ["claude.exe", "claude.cmd"]) {
      const p = join(dir, name);
      if (existsSync(p)) return p;
    }
  }
  return null;
}

// Environment for spawning claude.exe: drops CLAUDE*/ANTHROPIC* vars so a launch from
// inside another Claude session (or with a stray API key) still uses the stored claude.ai login.
// Cleanups are meant to be disposable, so it also turns off everything local or optional that
// Claude Code would otherwise keep or send. configDir picks which login folder (account) to use;
// null leaves CLAUDE_CONFIG_DIR unset, i.e. the default ~/.claude.
export function claudeEnv(configDir = null) {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (!/^(CLAUDE|ANTHROPIC)/i.test(k)) env[k] = v;
  }
  env.CLAUDE_CODE_SKIP_PROMPT_HISTORY = "1"; // no transcript / prompt history (on top of --no-session-persistence)
  env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"; // no metrics, error reports, surveys or feature-flag fetches
  if (configDir) env.CLAUDE_CONFIG_DIR = configDir;
  return env;
}

export function findClaudeBin() {
  const override = process.env.OPENWHISPR_PROXY_CLAUDE_BIN;
  if (override) {
    if (!existsSync(override)) throw new Error(`OPENWHISPR_PROXY_CLAUDE_BIN does not exist: ${override}`);
    return override;
  }
  const fromPath = onPath();
  if (fromPath) return fromPath;

  const local = process.env.LOCALAPPDATA;
  const candidates = [];
  if (local && existsSync(local)) {
    for (const entry of readdirSync(local)) {
      if (entry.startsWith("Claude")) candidates.push(...newestClaudeIn(join(local, entry)));
    }
  }
  candidates.sort((a, b) => b.mtime - a.mtime);
  if (candidates.length) return candidates[0].exe;

  throw new Error(
    "claude.exe not found. Install Claude Code, or set OPENWHISPR_PROXY_CLAUDE_BIN to its full path."
  );
}
