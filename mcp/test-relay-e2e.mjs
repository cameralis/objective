#!/usr/bin/env node
// The whole shared-bot path, in one process tree: the MCP server posts an item
// to a real relay over HTTP, a Telegram button tap hits the relay webhook, and
// the answer must come back as the result of the blocked objective_add call and
// land in the local board file.
// Run: node mcp/test-relay-e2e.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import worker, { Board } from "../relay/src/worker.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "objective-e2e-"));
const stateFile = path.join(stateDir, "state.json");
const CHAT = 777;

// MARK: - The relay, running for real over HTTP

class FakeStorage {
  constructor() {
    this.map = new Map();
  }
  async get(key) {
    return this.map.get(key);
  }
  async put(key, value) {
    this.map.set(key, JSON.parse(JSON.stringify(value)));
  }
  async delete(key) {
    this.map.delete(key);
  }
  async list({ prefix }) {
    return new Map([...this.map].filter(([key]) => key.startsWith(prefix)));
  }
}

const instances = new Map();
const env = {
  BOARD: {
    idFromName: (name) => ({ name }),
    get: (id) => ({
      fetch: (input, init) => {
        if (!instances.has(id.name)) {
          instances.set(id.name, new Board({ storage: new FakeStorage() }, env));
        }
        return instances.get(id.name).fetch(new Request(input, init));
      },
    }),
  },
  BOT_TOKEN: "test-token",
  KEY_SECRET: "signing-secret",
  WEBHOOK_SECRET: "hook-secret",
  TELEGRAM_API: "https://api.telegram.test",
};

const telegramCalls = [];
const realFetch = globalThis.fetch;
let nextMessageId = 900;
globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input.url;
  if (!url.startsWith(env.TELEGRAM_API)) return realFetch(input, init);
  const body = JSON.parse(init.body);
  telegramCalls.push({ method: url.split("/").pop(), body });
  return new Response(
    JSON.stringify({
      ok: true,
      result: { message_id: ++nextMessageId, chat: { id: body.chat_id } },
    }),
    { headers: { "content-type": "application/json" } }
  );
};

const relayServer = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const hasBody = chunks.length > 0;
  const response = await worker.fetch(
    new Request(`http://relay.test${req.url}`, {
      method: req.method,
      headers: req.headers,
      body: hasBody ? Buffer.concat(chunks) : undefined,
    }),
    env
  );
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
});

await new Promise((r) => relayServer.listen(0, "127.0.0.1", r));
const relayUrl = `http://127.0.0.1:${relayServer.address().port}`;

const hook = (update) =>
  realFetch(`${relayUrl}/telegram/webhook`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-telegram-bot-api-secret-token": env.WEBHOOK_SECRET,
    },
    body: JSON.stringify(update),
  });

// MARK: - Pair like a user would

await hook({ message: { chat: { id: CHAT }, text: "/start" } });
const code = telegramCalls.at(-1).body.text.match(/<code>([A-Z0-9]{8})<\/code>/)[1];
const paired = await realFetch(`${relayUrl}/v1/pair`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code }),
}).then((r) => r.json());
assert.ok(paired.account_key, "pairing produced no key");

// MARK: - The MCP server, pointed at the relay

fs.writeFileSync(stateFile, JSON.stringify({ rev: 0, items: [] }));
const server = spawn(process.execPath, [path.join(here, "index.js")], {
  env: {
    ...process.env,
    OBJECTIVE_STATE_DIR: stateDir,
    OBJECTIVE_APP: path.join(stateDir, "no-such-app"),
    OBJECTIVE_RELAY_URL: relayUrl,
    OBJECTIVE_RELAY_KEY: paired.account_key,
    OBJECTIVE_PRESENCE_CHECK_SECONDS: "1",
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
    waiters.get(message.id)?.(message);
    waiters.delete(message.id);
  }
});

let nextId = 1;
const send = (method, params) => {
  const id = nextId++;
  server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  return new Promise((resolve) => waiters.set(id, resolve));
};
const call = (name, args) => send("tools/call", { name, arguments: args });
const payload = (response) => JSON.parse(response.result.content[0].text);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const readBoard = () => JSON.parse(fs.readFileSync(stateFile, "utf8"));
const messagesAbout = (text) =>
  telegramCalls.filter((c) => c.method === "sendMessage" && c.body.text?.includes(text));
const editsAbout = (text) =>
  telegramCalls.filter((c) => c.method === "editMessageText" && c.body.text?.includes(text));

async function eventually(find, ms = 5000) {
  const end = Date.now() + ms;
  for (;;) {
    const value = find();
    if (value) return value;
    if (Date.now() > end) return null;
    await sleep(50);
  }
}

// Stands in for the app's reading. The test process is alive, so the reading
// counts as live.
function setPresence(state) {
  const file = path.join(stateDir, "presence.json");
  fs.writeFileSync(
    `${file}.tmp-test`,
    JSON.stringify({ state, reason: "test", since: Date.now() / 1000, locked: false, realInput: true, pid: process.pid })
  );
  fs.renameSync(`${file}.tmp-test`, file);
}

const openItem = (text) =>
  eventually(() => readBoard().items.find((i) => i.text === text && i.status === "open"));

function answerOnBoard(id, answer) {
  const board = readBoard();
  const item = board.items.find((i) => i.id === id);
  item.status = "done";
  item.answer = answer;
  item.doneAt = Date.now() / 1000;
  board.rev += 1;
  fs.writeFileSync(`${stateFile}.tmp-test`, JSON.stringify(board));
  fs.renameSync(`${stateFile}.tmp-test`, stateFile);
}

const tapButton = (message, index) =>
  hook({
    callback_query: {
      id: `q-${Date.now()}`,
      data: message.body.reply_markup.inline_keyboard.flat()[index].callback_data,
      message: { message_id: 1, chat: { id: CHAT } },
    },
  });

let failure = null;
try {
  await send("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "test", version: "1.0.0" },
  });
  server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized", params: {} })}\n`);

  // 1. The item reaches Telegram, with buttons, while the call stays open.
  const pending = call("objective_add", {
    text: "Deploy to production?",
    choices: ["Deploy", "Hold"],
    source: "objective",
  });

  let sentMessage = null;
  for (let i = 0; i < 100 && !sentMessage; i++) {
    sentMessage = telegramCalls.find((c) => c.body.text?.includes("Deploy to production?"));
    if (!sentMessage) await sleep(50);
  }
  assert.ok(sentMessage, "the relay never sent the Telegram message");
  const buttons = sentMessage.body.reply_markup.inline_keyboard.flat();
  assert.deepEqual(buttons.map((b) => b.text), ["Deploy", "Hold"]);

  let settled = false;
  pending.then(() => (settled = true));
  await sleep(300);
  assert.equal(settled, false, "objective_add returned before anyone answered");

  // 2. Tapping the button in Telegram releases the agent.
  await hook({
    callback_query: {
      id: "q1",
      data: buttons[0].callback_data,
      message: { message_id: sentMessage.body.message_id, chat: { id: CHAT } },
    },
  });

  const answered = payload(await pending);
  assert.equal(answered.result, "done");
  assert.equal(answered.answer, "Deploy");
  assert.equal(answered.via, "telegram");

  // 3. The overlay must show the same answer, so both front ends agree.
  const local = JSON.parse(fs.readFileSync(stateFile, "utf8")).items.at(-1);
  assert.equal(local.status, "done");
  assert.equal(local.answer, "Deploy");

  // 4. An answer given on the Mac closes the Telegram message instead.
  const note = payload(await call("objective_add", { text: "Check the logs", wait: false }));
  const waiting = call("objective_wait", { id: note.item.id, timeout_seconds: 20 });
  await sleep(200);
  const board = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  const item = board.items.find((i) => i.id === note.item.id);
  item.status = "done";
  item.answer = "logs are clean";
  item.doneAt = Date.now() / 1000;
  board.rev += 1;
  fs.writeFileSync(`${stateFile}.tmp-test`, JSON.stringify(board));
  fs.renameSync(`${stateFile}.tmp-test`, stateFile);

  assert.equal(payload(await waiting).answer, "logs are clean");
  for (let i = 0; i < 100; i++) {
    if (telegramCalls.some((c) => c.method === "editMessageText" && c.body.text.includes("Check the logs"))) break;
    await sleep(50);
  }
  const edit = telegramCalls.findLast((c) => c.method === "editMessageText");
  assert.match(edit.body.text, /✅ <s>Check the logs<\/s>/);
  assert.match(edit.body.text, /💬 <b>logs are clean<\/b>/);

  // 5. A user at the Mac gets no push. Leaving sends the open item to Telegram.
  setPresence("present");
  const leaving = call("objective_add", { text: "Rotate the API key", choices: ["Rotate", "Keep"] });
  await openItem("Rotate the API key");
  await sleep(1500);
  assert.equal(messagesAbout("Rotate the API key").length, 0, "a user at the Mac got a Telegram message");
  setPresence("away");
  const rotate = await eventually(() => messagesAbout("Rotate the API key")[0]);
  assert.ok(rotate, "leaving the Mac did not send the open item to Telegram");
  await tapButton(rotate, 0);
  assert.equal(payload(await leaving).answer, "Rotate");

  // 6. An unsure user who reacts to the banner in time gets no push.
  setPresence("unsure");
  const noticed = call("objective_add", { text: "Pick the icon", choices: ["Round", "Square"] });
  const icon = await openItem("Pick the icon");
  await sleep(300);
  setPresence("present");
  await sleep(1500);
  assert.equal(messagesAbout("Pick the icon").length, 0, "a user who reacted in time got a Telegram message");
  answerOnBoard(icon.id, "Round");
  assert.equal(payload(await noticed).answer, "Round");

  // 7. An unsure user who lets the banner pass gets the push after the check.
  setPresence("unsure");
  const missed = call("objective_add", { text: "Approve the invoice", choices: ["Approve", "Reject"] });
  const invoice = await openItem("Approve the invoice");
  await sleep(300);
  assert.equal(messagesAbout("Approve the invoice").length, 0, "the push came before the check ended");
  assert.ok(await eventually(() => messagesAbout("Approve the invoice")[0]), "no push after the check");
  answerOnBoard(invoice.id, "Approve");
  assert.equal(payload(await missed).answer, "Approve");
  assert.ok(await eventually(() => editsAbout("Approve the invoice")[0]), "the chat message stayed open");

  // 8. A step at the Mac waits while the user is away, and goes on when the user is back.
  setPresence("away");
  const touch = call("objective_add", { text: "Touch ID for brew upgrade", at_mac: true });
  const touchMessage = await eventually(() => messagesAbout("Touch ID for brew upgrade")[0]);
  assert.ok(touchMessage, "an away user got no Telegram message for a step at the Mac");
  assert.match(touchMessage.body.text, /Waits for you at the Mac/);
  assert.deepEqual(touchMessage.body.reply_markup.inline_keyboard.flat().map((b) => b.text), ["Skip"]);
  let touchSettled = false;
  touch.then(() => (touchSettled = true));
  await sleep(300);
  assert.equal(touchSettled, false, "at_mac returned while the user was away");
  setPresence("present");
  const touched = payload(await touch);
  assert.equal(touched.result, "present");
  assert.ok(
    await eventually(() => editsAbout("Touch ID for brew upgrade").find((c) => c.body.text.includes("At the Mac"))),
    "the chat message did not say that the user is back"
  );

  // 9. Skip from the phone means the agent must not start the step.
  setPresence("away");
  const sudo = call("objective_add", { text: "Enter the sudo password", at_mac: true });
  const sudoMessage = await eventually(() => messagesAbout("Enter the sudo password")[0]);
  await tapButton(sudoMessage, 0);
  const skipped = payload(await sudo);
  assert.equal(skipped.result, "skipped");
  assert.equal(skipped.answer, "Skip");

  console.log("all relay end-to-end tests passed");
} catch (err) {
  failure = err;
} finally {
  server.kill();
  relayServer.close();
  fs.rmSync(stateDir, { recursive: true, force: true });
}

if (failure) {
  console.error(failure);
  process.exit(1);
}
