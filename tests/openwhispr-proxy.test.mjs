// Tests for the OpenWhispr proxy (openwhispr\server.mjs). Run: node --test tests/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// Importing the server creates its data folder, so point it at a temp folder first.
process.env.OPENWHISPR_PROXY_DATA = mkdtempSync(join(tmpdir(), "ow-data-"));
const { splitMessages, contentLoggingSettings } = await import("../openwhispr/server.mjs");

test("system messages become the system prompt; the rest is the input text", () => {
  const { system, text } = splitMessages([
    { role: "system", content: "clean up" },
    { role: "system", content: "do not answer" },
    { role: "user", content: "<t>é então</t>" },
  ]);
  assert.equal(system, "clean up\n\ndo not answer");
  assert.equal(text, "<t>é então</t>");
});

test("array content parts are joined", () => {
  const { text } = splitMessages([{ role: "user", content: [{ type: "text", text: "a" }, { type: "text", text: "b" }] }]);
  assert.equal(text, "ab");
});

test("detects org settings that would log prompt content", () => {
  const dir = mkdtempSync(join(tmpdir(), "ow-test-"));
  const clean = join(dir, "clean.json"), risky = join(dir, "risky.json");
  writeFileSync(clean, JSON.stringify({ env: { DISABLE_TELEMETRY: "1" } }));
  writeFileSync(risky, JSON.stringify({ env: { OTEL_LOG_USER_PROMPTS: "1" } }));
  assert.deepEqual(contentLoggingSettings([clean, join(dir, "missing.json")]), []);
  assert.equal(contentLoggingSettings([risky]).length, 1);
});

test("missing messages yield empty strings", () => {
  assert.deepEqual(splitMessages(undefined), { system: "", text: "" });
});
