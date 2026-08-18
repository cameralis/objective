#!/usr/bin/env node
// End-to-end test for the bridge against a fake Telegram server.
// Run: node telegram/test-bridge.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "objective-test-"));
const stateFile = path.join(stateDir, "state.json");

const sent = []; // sendMessage calls
const edits = []; // editMessageText calls
const toasts = []; // answerCallbackQuery calls
let pending = []; // updates handed to the next getUpdates
let messageId = 100;

const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", async () => {
    const method = req.url.split("/").pop();
    const payload = body ? JSON.parse(body) : {};
    let result = true;

    if (method === "getMe") {
      result = { username: "fake_bot" };
    } else if (method === "getUpdates") {
      // Long poll: answer as soon as something is queued.
      for (let i = 0; i < 100 && !pending.length; i++) await sleep(50);
      result = pending;
      pending = [];
    } else if (method === "sendMessage") {
      sent.push(payload);
      result = { message_id: ++messageId, chat: { id: payload.chat_id } };
    } else if (method === "editMessageText") {
      edits.push(payload);
      result = { message_id: payload.message_id };
    } else if (method === "answerCallbackQuery") {
      toasts.push(payload);
    }

    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ ok: true, result }));
  });
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(label, check, timeout = 5000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = check();
    if (value) return value;
    await sleep(50);
  }
  throw new Error(`timed out waiting for ${label}`);
}

const readBoard = () => JSON.parse(fs.readFileSync(stateFile, "utf8"));

function writeBoard(state) {
  const tmp = `${stateFile}.tmp-test`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, stateFile);
}

function addItem(item) {
  const state = readBoard();
  state.items.push({ status: "open", createdAt: Date.now() / 1000, ...item });
  state.rev += 1;
  writeBoard(state);
}

await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

writeBoard({ rev: 0, items: [] });

const bridge = spawn(process.execPath, [path.join(here, "bridge.js")], {
  env: {
    ...process.env,
    OBJECTIVE_STATE_DIR: stateDir,
    OBJECTIVE_TELEGRAM_API: base,
    OBJECTIVE_TELEGRAM_TOKEN: "test-token",
    OBJECTIVE_TELEGRAM_CHAT_ID: "4242",
  },
  stdio: ["ignore", "inherit", process.env.VERBOSE ? "inherit" : "ignore"],
});

let failure = null;
try {
  await waitFor("bridge online", () => fs.existsSync(path.join(stateDir, "telegram-state.json")));

  // 1. A choice item becomes a message with inline buttons.
  addItem({ id: "item-choice", text: "Ship the migration?", detail: "3 tables", choices: ["Ship it", "Wait"], source: "objective" });
  const choiceMsg = await waitFor("choice message", () => sent.find((m) => m.text.includes("Ship the migration?")));
  assert.equal(String(choiceMsg.chat_id), "4242");
  const rows = choiceMsg.reply_markup.inline_keyboard;
  assert.deepEqual(rows.flat().map((b) => b.text), ["Ship it", "Wait"]);
  assert.match(choiceMsg.text, /🎯 <b>Ship the migration\?<\/b>/);
  assert.match(choiceMsg.text, /#objective/);

  // 2. Tapping a button answers the item on the board.
  pending.push({ update_id: 1, callback_query: { id: "q1", data: rows.flat()[0].callback_data, message: { message_id: 101, chat: { id: 4242 } } } });
  const answered = await waitFor("choice answer", () => readBoard().items.find((i) => i.id === "item-choice" && i.answer));
  assert.equal(answered.answer, "Ship it");
  assert.equal(answered.status, "done");
  await waitFor("toast", () => toasts.length);
  const choiceEdit = await waitFor("choice edit", () => edits.find((e) => e.text.includes("Ship the migration?")));
  assert.match(choiceEdit.text, /✅ <s>Ship the migration\?<\/s>/);
  assert.match(choiceEdit.text, /💬 <b>Ship it<\/b>/);

  // 3. A reply item asks for text and takes a plain message as the answer.
  addItem({ id: "item-reply", text: "Name the release", allowReply: true });
  const replyMsg = await waitFor("reply message", () => sent.find((m) => m.text.includes("Name the release")));
  assert.equal(replyMsg.reply_markup.force_reply, true);
  pending.push({ update_id: 2, message: { message_id: 900, text: "v2.1 Glasswing", chat: { id: 4242 } } });
  const named = await waitFor("text answer", () => readBoard().items.find((i) => i.id === "item-reply" && i.answer));
  assert.equal(named.answer, "v2.1 Glasswing");

  // 4. A plain urgent item gets a Done button, and a reply to it answers it.
  addItem({ id: "item-plain", text: "Plug in the test phone", urgent: true });
  const plainMsg = await waitFor("plain message", () => sent.find((m) => m.text.includes("Plug in the test phone")));
  assert.match(plainMsg.text, /🔴/);
  assert.equal(plainMsg.reply_markup.inline_keyboard[0][0].text, "✓ Done");
  const plainId = sent.indexOf(plainMsg) + 101;
  pending.push({ update_id: 3, message: { message_id: 901, text: "plugged in", reply_to_message: { message_id: plainId }, chat: { id: 4242 } } });
  const plugged = await waitFor("reply-to answer", () => readBoard().items.find((i) => i.id === "item-plain" && i.answer));
  assert.equal(plugged.answer, "plugged in");

  // 5. An item completed elsewhere (overlay or Claude) updates the chat message.
  addItem({ id: "item-outside", text: "Review the PR" });
  await waitFor("outside message", () => sent.find((m) => m.text.includes("Review the PR")));
  const state = readBoard();
  const outside = state.items.find((i) => i.id === "item-outside");
  outside.status = "done";
  outside.doneAt = Date.now() / 1000;
  state.rev += 1;
  writeBoard(state);
  const outsideEdit = await waitFor("outside edit", () => edits.find((e) => e.text.includes("Review the PR")));
  assert.match(outsideEdit.text, /✅ <s>Review the PR<\/s>/);
  assert.equal(outsideEdit.reply_markup, undefined);

  // 6. A withdrawn item is struck through, not left dangling.
  addItem({ id: "item-gone", text: "Confirm the invoice" });
  await waitFor("gone message", () => sent.find((m) => m.text.includes("Confirm the invoice")));
  const pruned = readBoard();
  pruned.items = pruned.items.filter((i) => i.id !== "item-gone");
  pruned.rev += 1;
  writeBoard(pruned);
  const goneEdit = await waitFor("gone edit", () => edits.find((e) => e.text.includes("Confirm the invoice")));
  assert.match(goneEdit.text, /🚫 <s>Confirm the invoice<\/s>/);

  // 7. /list answers with the open items.
  addItem({ id: "item-open", text: "Approve the DB migration" });
  await waitFor("open message", () => sent.find((m) => m.text.includes("Approve the DB migration")));
  pending.push({ update_id: 4, message: { message_id: 902, text: "/list", chat: { id: 4242 } } });
  const list = await waitFor("/list reply", () => sent.find((m) => m.text.includes("<b>1 open</b>")));
  assert.match(list.text, /Approve the DB migration/);

  console.log("all bridge tests passed");
} catch (err) {
  failure = err;
} finally {
  bridge.kill();
  server.close();
  fs.rmSync(stateDir, { recursive: true, force: true });
}

if (failure) {
  console.error(failure);
  process.exit(1);
}
