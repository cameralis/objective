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
    OBJECTIVE_PRESENCE_CHECK_SECONDS: "1",
    OBJECTIVE_AT_MAC_HOLD_SECONDS: "1",
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

// Stands in for the app's reading. The test process is alive, so by default
// the reading counts as live.
function setPresence(state, pid = process.pid) {
  const file = path.join(stateDir, "presence.json");
  fs.writeFileSync(
    `${file}.tmp-test`,
    JSON.stringify({ state, reason: "test", since: Date.now() / 1000, locked: false, realInput: true, pid })
  );
  fs.renameSync(`${file}.tmp-test`, file);
}

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

async function waitForOpenItem(text) {
  for (let i = 0; i < 100; i++) {
    try {
      const open = readBoard().items.filter(
        (x) => x.status === "open" && (text == null || x.text === text)
      );
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

  // 6. Stopping the tool call takes the question off the board: the agent that
  //    asked is gone, so nobody would ever read the answer.
  const stopped = call("objective_add", {
    text: "Paste the issuer id",
    choices: ["Paste it", "Skip"],
  });
  stopped.catch(() => {});
  const orphan = await waitForOpenItem("Paste the issuer id");
  notify("notifications/cancelled", {
    requestId: nextId - 1,
    reason: "user stopped the tool call",
  });
  for (let i = 0; i < 100 && readBoard().items.some((x) => x.id === orphan.id); i++) {
    await sleep(20);
  }
  assert.equal(
    readBoard().items.some((x) => x.id === orphan.id),
    false,
    "a stopped objective_add left its item on the board"
  );

  // 7. Without the app nobody knows where the user is, so the user says it.
  assert.equal(payload(await call("objective_presence", {})).state, "unknown");
  const unknownStep = call("objective_add", { text: "Touch ID for the keychain", at_mac: true });
  const unknownItem = await waitForOpenItem("Touch ID for the keychain");
  assert.deepEqual(unknownItem.choices, ["Ready", "Skip"]);
  userAnswers(unknownItem.id, "Ready");
  assert.equal(payload(await unknownStep).result, "present");

  // 8. A user at the Mac gets the step at once. The item stays on the board
  //    long enough to read, asks nothing, and then closes itself.
  setPresence("present");
  const presence = payload(await call("objective_presence", {}));
  assert.equal(presence.state, "present");
  assert.equal(presence.reason, "test");
  const atOnce = payload(
    await call("objective_add", { text: "Touch ID for brew upgrade", at_mac: true })
  );
  assert.equal(atOnce.result, "present");
  const readyItem = readBoard().items.find((x) => x.id === atOnce.id);
  assert.equal(readyItem.status, "open", "the step was done before the user could read it");
  assert.ok(readyItem.readyAt, "the board was not told that the user is at the Mac");
  assert.equal(readyItem.choices, undefined, "an announcement must not ask anything");
  const held = () => readBoard().items.find((x) => x.id === atOnce.id);
  for (let i = 0; i < 200 && held().status === "open"; i++) await sleep(20);
  assert.equal(held().status, "done", "the step stayed on the board after it ended");
  assert.equal(held().answer, "At the Mac");

  // 9. An unsure user who comes back releases the step, with no click.
  setPresence("unsure");
  const comeBack = call("objective_add", { text: "Approve the system dialog", at_mac: true });
  const waitingItem = await waitForOpenItem("Approve the system dialog");
  assert.deepEqual(waitingItem.choices, ["Skip"]);
  let back = false;
  comeBack.then(() => (back = true));
  await sleep(300);
  assert.equal(back, false, "at_mac returned while the user was not at the Mac");
  setPresence("present");
  assert.equal(payload(await comeBack).result, "present");
  assert.equal(readBoard().items.find((x) => x.id === waitingItem.id).answer, "At the Mac");

  // 10. Skip means the agent must not start the step.
  setPresence("away");
  const skipped = call("objective_add", { text: "Enter the sudo password", at_mac: true });
  const skipItem = await waitForOpenItem("Enter the sudo password");
  userAnswers(skipItem.id, "Skip");
  assert.equal(payload(await skipped).result, "skipped");

  // 11. A reading from an app that quit says nothing.
  setPresence("present", 999999);
  assert.equal(payload(await call("objective_presence", {})).state, "unknown");

  // 12. Killing the server does the same for everything it still waits on.
  const killed = call("objective_add", { text: "Approve the deploy" });
  killed.catch(() => {});
  const leftover = await waitForOpenItem("Approve the deploy");
  server.kill("SIGTERM");
  for (let i = 0; i < 100 && readBoard().items.some((x) => x.id === leftover.id); i++) {
    await sleep(20);
  }
  assert.equal(
    readBoard().items.some((x) => x.id === leftover.id),
    false,
    "a killed server left its item on the board"
  );

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
