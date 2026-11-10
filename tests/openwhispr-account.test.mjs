// Tests for the OpenWhispr proxy account handling (openwhispr/account.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { readAccount, accountInfo, DEFAULT_ACCOUNT } from "../openwhispr/account.mjs";
import { claudeEnv } from "../openwhispr/claudeBin.mjs";

const tmp = () => mkdtempSync(join(tmpdir(), "ow-acct-"));

test("missing or broken account.json falls back to the default folder", () => {
  const dir = tmp();
  assert.deepEqual(readAccount(join(dir, "nope.json")), DEFAULT_ACCOUNT);
  writeFileSync(join(dir, "bad.json"), "{not json");
  assert.deepEqual(readAccount(join(dir, "bad.json")), DEFAULT_ACCOUNT);
});

test("account.json with a folder (and a BOM, as PowerShell writes it)", () => {
  const dir = tmp();
  const f = join(dir, "account.json");
  writeFileSync(f, "\uFEFF" + JSON.stringify({ configDir: "C:\\Users\\x\\.claude-Work", label: "Work" }));
  assert.deepEqual(readAccount(f), { configDir: "C:\\Users\\x\\.claude-Work", label: "Work" });
  writeFileSync(f, JSON.stringify({ configDir: null, label: "Default" }));
  assert.deepEqual(readAccount(f), { configDir: null, label: "Default" });
});

test("accountInfo reads oauthAccount from the folder, or from home for the default", () => {
  const home = tmp();
  const work = join(home, ".claude-Work");
  mkdirSync(work);
  writeFileSync(join(work, ".claude.json"), JSON.stringify({ oauthAccount: { emailAddress: "a@b.com", organizationName: "Org" } }));
  assert.deepEqual(accountInfo(work, home), { email: "a@b.com", organization: "Org", signedIn: true });
  assert.deepEqual(accountInfo(null, home), { email: null, organization: null, signedIn: false });
  writeFileSync(join(home, ".claude.json"), JSON.stringify({ oauthAccount: { emailAddress: "me@x.com" } }));
  assert.equal(accountInfo(null, home).email, "me@x.com");
});

test("claudeEnv sets CLAUDE_CONFIG_DIR only for a chosen folder", () => {
  assert.equal(claudeEnv("C:\\acct").CLAUDE_CONFIG_DIR, "C:\\acct");
  assert.equal("CLAUDE_CONFIG_DIR" in claudeEnv(null), false);
  assert.equal(claudeEnv(null).CLAUDE_CODE_SKIP_PROMPT_HISTORY, "1");
});
