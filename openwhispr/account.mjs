// Which Claude account the proxy uses. The Claude Profile Switcher writes
// %LOCALAPPDATA%\ClaudeProfiles\.openwhispr\account.json:
//   { "configDir": "C:\\Users\\you\\.claude-Work" | null, "label": "Work", "profileId": "Work" }
// configDir is a Claude Code login folder (CLAUDE_CONFIG_DIR); null or a missing file means the
// default ~/.claude.
import { readFileSync } from "node:fs";
import { join } from "node:path";

export const DEFAULT_ACCOUNT = Object.freeze({ configDir: null, label: "default" });

export function readAccount(file) {
  let raw;
  try { raw = readFileSync(file, "utf8").replace(/^\uFEFF/, ""); } catch { return DEFAULT_ACCOUNT; }
  try {
    const j = JSON.parse(raw);
    const configDir = typeof j.configDir === "string" && j.configDir.trim() ? j.configDir.trim() : null;
    const label = typeof j.label === "string" && j.label.trim() ? j.label.trim() : configDir ? configDir : "default";
    return { configDir, label };
  } catch {
    return DEFAULT_ACCOUNT;
  }
}

// Who a Claude Code folder is signed in as, from the oauthAccount Claude Code keeps in
// .claude.json (the credentials file is never opened). For the default folder that file lives
// in the home directory, next to ~/.claude, not inside it.
export function accountInfo(configDir, home = process.env.USERPROFILE || "") {
  const stateFile = configDir ? join(configDir, ".claude.json") : join(home, ".claude.json");
  try {
    const raw = readFileSync(stateFile, "utf8");
    let email = null, organization = null;
    try {
      const a = JSON.parse(raw).oauthAccount;
      if (a) { email = a.emailAddress ?? null; organization = a.organizationName ?? null; }
    } catch {
      email = /"emailAddress"\s*:\s*"([^"]+)"/.exec(raw)?.[1] ?? null;
      organization = /"organizationName"\s*:\s*"([^"]*)"/.exec(raw)?.[1] ?? null;
    }
    return { email, organization, signedIn: Boolean(email) };
  } catch {
    return { email: null, organization: null, signedIn: false };
  }
}
