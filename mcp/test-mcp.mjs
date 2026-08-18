#!/usr/bin/env node
// Checks that objective_add blocks and returns the user's answer the moment it
// is written, without any further tool call.
// Run: node mcp/test-mcp.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "objective-mcp-test-"));
const stateFile = path.join(stateDir, "state.json");

const server = spawn(process.execPath, [path.join(here, "index.js")], {
  env: {
    ...process.env,
    OBJECTIVE_STATE_DIR: stateDir,
    OBJECTIVE_APP: path.join(stateDir, "no-such-app"),
  },
  stdio: ["pipe", "pipe", process.env.VERBOSE ? "inherit" : "ignore"],
});

let buffer = "";
const waiters = new Map();
server.stdout.on("data", (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    const waiter = waiters.get(message.id);
    if (waiter) {
      waiters.delete(message.id);
      waiter(message);
    }
  }
});

let nextId = 1;
function send(method, params) {
  const id = nextId++;
  server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  return new Promise((resolve) => waiters.set(id, resolve));
}

const notify = (method, params) =>
  server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);

const call = (name, args) => send("tools/call", { name, arguments: args });
const payload = (response) => JSON.parse(response.result.content[0].text);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const readBoard = () => JSON.parse(fs.readFileSync(stateFile, "utf8"));

// Stands in for a click in the overlay or a button tap in Telegram.
function userAnswers(id, answer) {
  const state = readBoard();
  const item = state.items.find((i) => i.id === id);
  const now = Date.now() / 1000;
  if (answer != null) {
    item.answer = answer;
    item.answeredAt = now;
  }
  item.status = "done";
  item.doneAt = now;
  state.rev += 1;
  const tmp = `${stateFile}.tmp-test`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, stateFile);
}

async function waitForOpenItem() {
  for (let i = 0; i < 100; i++) {
    try {
      const open = readBoard().items.filter((x) => x.status === "open");
      if (open.length) return open[open.length - 1];
    } catch {}
    await sleep(20);
  }
  throw new Error("no item appeared on the board");
}

let failure = null;
try {
  await send("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "test", version: "1.0.0" },
  });
  notify("notifications/initialized", {});

  // 1. objective_add blocks, then returns the clicked choice by itself.
  const started = Date.now();
  const pending = call("objective_add", {
    text: "Ship the migration?",
    choices: ["Ship it", "Wait"],
    source: "test",
  });
  const item = await waitForOpenItem();
  assert.equal(item.text, "Ship the migration?");

  let settled = false;
  pending.then(() => (settled = true));
  await sleep(300);
  assert.equal(settled, false, "objective_add returned before the user answered");

  userAnswers(item.id, "Ship it");
  const answered = payload(await pending);
  assert.equal(answered.result, "done");
  assert.equal(answered.answer, "Ship it");
  assert.ok(Date.now() - started < 5000, "answer took too long to come back");

  // 2. A plain check-off also releases the call.
  const checking = call("objective_add", { text: "Plug in the test phone" });
  const chore = await waitForOpenItem();
  userAnswers(chore.id, null);
  const checked = payload(await checking);
  assert.equal(checked.result, "done");
  assert.equal(checked.answer, null);
  assert.equal(checked.answered, false);

  // 3. wait: false returns at once, and objective_wait picks the answer up later.
  const note = payload(
    await call("objective_add", { text: "Read the release notes", wait: false })
  );
  assert.equal(note.item.status, "open");
  const later = call("objective_wait", { id: note.item.id, timeout_seconds: 10 });
  userAnswers(note.item.id, "read them");
  assert.equal(payload(await later).answer, "read them");

  // 4. A removed item ends the wait instead of hanging.
  const dropped = payload(
    await call("objective_add", { text: "Confirm the invoice", wait: false })
  );
  const waiting = call("objective_wait", { id: dropped.item.id, timeout_seconds: 10 });
  await call("objective_remove", { id: dropped.item.id });
  assert.equal(payload(await waiting).result, "removed");

  // 5. A short timeout gives up cleanly and says how to keep waiting.
  const timing = payload(
    await call("objective_add", { text: "Nobody answers this", timeout_seconds: 5 })
  );
  assert.equal(timing.result, "timeout");
  assert.match(timing.note, /objective_wait/);

  console.log("all mcp tests passed");
} catch (err) {
  failure = err;
} finally {
  server.kill();
  fs.rmSync(stateDir, { recursive: true, force: true });
}

if (failure) {
  console.error(failure);
  process.exit(1);
}
