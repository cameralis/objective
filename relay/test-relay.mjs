#!/usr/bin/env node
// Drives the Worker and its Durable Object in plain Node, with stubbed storage
// and a stubbed Telegram API. No wrangler and no deployment needed.
// Run: node relay/test-relay.mjs

import assert from "node:assert/strict";
import worker, { Board } from "./src/worker.js";

// MARK: - Stubs

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
    return new Map(
      [...this.map].filter(([key]) => key.startsWith(prefix))
    );
  }
}

const instances = new Map();
const BOARD = {
  idFromName: (name) => ({ name }),
  get: (id) => ({
    fetch: (input, init) => {
      if (!instances.has(id.name)) {
        instances.set(id.name, new Board({ storage: new FakeStorage() }, env));
      }
      return instances.get(id.name).fetch(new Request(input, init));
    },
  }),
};

const calls = { sendMessage: [], editMessageText: [], answerCallbackQuery: [] };
let nextMessageId = 500;

const env = {
  BOARD,
  BOT_TOKEN: "test-token",
  KEY_SECRET: "signing-secret",
  WEBHOOK_SECRET: "hook-secret",
  TELEGRAM_API: "https://api.telegram.test",
};

const realFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input.url;
  if (!url.startsWith(env.TELEGRAM_API)) return realFetch(input, init);
  const method = url.split("/").pop();
  const body = JSON.parse(init.body);
  calls[method]?.push(body);
  return new Response(
    JSON.stringify({
      ok: true,
      result: { message_id: ++nextMessageId, chat: { id: body.chat_id } },
    }),
    { headers: { "content-type": "application/json" } }
  );
};

// MARK: - Helpers

const CHAT = 4242;

const hook = (update, secret = env.WEBHOOK_SECRET) =>
  worker.fetch(
    new Request("https://relay.test/telegram/webhook", {
      method: "POST",
      headers: { "x-telegram-bot-api-secret-token": secret },
      body: JSON.stringify(update),
    }),
    env
  );

const api = (path, { method = "GET", key, body } = {}) =>
  worker.fetch(
    new Request(`https://relay.test${path}`, {
      method,
      headers: key ? { authorization: `Bearer ${key}` } : {},
      body: body ? JSON.stringify(body) : undefined,
    }),
    env
  );

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// MARK: - Tests

// 1. /start hands out a pairing code, and the code buys an account key.
await hook({ message: { chat: { id: CHAT }, text: "/start" } });
const codeMessage = calls.sendMessage.at(-1).text;
const code = codeMessage.match(/<code>([A-Z0-9]{8})<\/code>/)[1];

const paired = await (await api("/v1/pair", { method: "POST", body: { code } })).json();
assert.match(paired.account_key, /^ob1\./);
const key = paired.account_key;

// A code works once only.
const reused = await api("/v1/pair", { method: "POST", body: { code } });
assert.equal(reused.status, 404);

// 2. An unsigned or absent key is refused.
assert.equal((await api("/v1/items", { method: "POST", body: { text: "x" } })).status, 401);
assert.equal(
  (await api("/v1/items", { method: "POST", key: "ob1.38.1.deadbeef", body: { text: "x" } }))
    .status,
  401
);
assert.equal((await hook({ message: { chat: { id: CHAT }, text: "/start" } }, "wrong")).status, 403);

// 3. An item becomes a Telegram message with buttons.
const created = await (
  await api("/v1/items", {
    method: "POST",
    key,
    body: { text: "Ship the migration?", choices: ["Ship it", "Wait"], source: "objective" },
  })
).json();
const sent = calls.sendMessage.at(-1);
assert.match(sent.text, /🎯 <b>Ship the migration\?<\/b>/);
assert.deepEqual(
  sent.reply_markup.inline_keyboard.flat().map((b) => b.text),
  ["Ship it", "Wait"]
);

// 4. A poll with no answer yet times out and says so.
const idle = await (await api(`/v1/item?id=${created.id}&wait=1`, { key })).json();
assert.equal(idle.status, "open");
assert.equal(idle.timed_out, true);

// 5. A long poll wakes the moment the button is tapped.
const started = Date.now();
const polling = api(`/v1/item?id=${created.id}&wait=20`, { key }).then((r) => r.json());
await sleep(100);
await hook({
  callback_query: {
    id: "q1",
    data: `c|${created.id}|0`,
    message: { message_id: sent.message_id, chat: { id: CHAT } },
  },
});
const answered = await polling;
assert.equal(answered.status, "done");
assert.equal(answered.answer, "Ship it");
assert.ok(Date.now() - started < 5000, "the long poll did not wake early");
assert.match(calls.editMessageText.at(-1).text, /💬 <b>Ship it<\/b>/);
assert.match(calls.answerCallbackQuery.at(-1).text, /Ship it/);

// 6. A plain text message answers the item that asked for text.
const reply = await (
  await api("/v1/items", { method: "POST", key, body: { text: "Name the release", allow_reply: true } })
).json();
await hook({ message: { chat: { id: CHAT }, text: "v2.1 Glasswing" } });
const named = await (await api(`/v1/item?id=${reply.id}`, { key })).json();
assert.equal(named.answer, "v2.1 Glasswing");

// 7. An answer given in the Mac overlay closes the chat message too.
const local = await (
  await api("/v1/items", { method: "POST", key, body: { text: "Review the PR" } })
).json();
await api("/v1/close", { method: "POST", key, body: { id: local.id, answer: "looked at it" } });
assert.match(calls.editMessageText.at(-1).text, /✅ <s>Review the PR<\/s>/);
assert.equal((await (await api(`/v1/item?id=${local.id}`, { key })).json()).answer, "looked at it");

// 8. /unlink kills every key the chat handed out.
await hook({ message: { chat: { id: CHAT }, text: "/unlink" } });
assert.equal((await api("/v1/items", { method: "POST", key, body: { text: "x" } })).status, 401);

console.log("all relay tests passed");
