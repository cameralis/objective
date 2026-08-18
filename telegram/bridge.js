#!/usr/bin/env node
// Objective -> Telegram bridge.
//
// Sends every open board item to a Telegram chat. Choice items become inline
// buttons, reply items ask for text. Answers are written back into the same
// state.json the overlay app and the MCP server use, so objective_wait sees
// them like any other answer.
//
// No dependencies: Node 18+ fetch and long polling only.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";

const STATE_DIR =
  process.env.OBJECTIVE_STATE_DIR ||
  path.join(os.homedir(), "Library", "Application Support", "Objective");
const STATE_FILE = path.join(STATE_DIR, "state.json");
const CONFIG_FILE = path.join(STATE_DIR, "telegram.json");
const BRIDGE_FILE = path.join(STATE_DIR, "telegram-state.json");

// On a first-ever run, items older than this are adopted silently instead of
// flooding the chat with a backlog.
const BACKFILL_MAX_AGE = 3600;
const MAX_SEND_FAILURES = 5;
const POLL_TIMEOUT = 30;

const log = (...args) => console.error("[objective-telegram]", ...args);

// MARK: - Files

function readJSON(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJSON(file, value) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const tmp = `${file}.tmp-tg`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
  fs.renameSync(tmp, file);
}

const readBoard = () => readJSON(STATE_FILE, { rev: 0, items: [] });

function mutateBoard(change) {
  const state = readBoard();
  const result = change(state);
  state.rev += 1;
  writeJSON(STATE_FILE, state);
  return result;
}

// { offset, sent: { itemId: { messageId, chatId, sig, status, failures } } }
let bridgeState = readJSON(BRIDGE_FILE, null);
const isFirstRun = bridgeState === null;
if (isFirstRun) bridgeState = { offset: 0, sent: {} };
const saveBridgeState = () => writeJSON(BRIDGE_FILE, bridgeState);

let config = readJSON(CONFIG_FILE, {});
const saveConfig = () => writeJSON(CONFIG_FILE, config);

// MARK: - Command line

const argv = process.argv.slice(2);
function takeFlag(name) {
  const i = argv.indexOf(name);
  if (i < 0) return null;
  const value = argv[i + 1];
  argv.splice(i, 2);
  return value ?? null;
}

if (argv.includes("--help") || argv.includes("-h")) {
  console.log(`objective telegram bridge

  --token <TOKEN>   save the bot token from @BotFather
  --chat <ID>       save the target chat id (else send /start to the bot)
  --status          show the current configuration and exit
  --reset           forget which items were already sent

Environment overrides: OBJECTIVE_TELEGRAM_TOKEN, OBJECTIVE_TELEGRAM_CHAT_ID`);
  process.exit(0);
}

const tokenArg = takeFlag("--token");
if (tokenArg) {
  config.token = tokenArg.trim();
  saveConfig();
  log("token saved to", CONFIG_FILE);
}

const chatArg = takeFlag("--chat");
if (chatArg) {
  config.chatId = Number(chatArg) || chatArg.trim();
  saveConfig();
  log("chat id saved:", config.chatId);
}

if (argv.includes("--reset")) {
  bridgeState = { offset: bridgeState.offset ?? 0, sent: {} };
  saveBridgeState();
  log("sent-message map cleared");
}

const TOKEN = process.env.OBJECTIVE_TELEGRAM_TOKEN || config.token || "";
let chatId = process.env.OBJECTIVE_TELEGRAM_CHAT_ID || config.chatId || null;

if (argv.includes("--status")) {
  console.log(
    JSON.stringify(
      {
        configFile: CONFIG_FILE,
        token: TOKEN ? `${TOKEN.slice(0, 8)}...` : null,
        chatId,
        tracked: Object.keys(bridgeState.sent).length,
      },
      null,
      2
    )
  );
  process.exit(0);
}

if (!TOKEN) {
  console.error(`No bot token.

1. Open Telegram, talk to @BotFather, send /newbot, copy the token.
2. Run: node ${path.relative(process.cwd(), process.argv[1])} --token <TOKEN>
3. Start the bridge, then send /start to your bot.`);
  process.exit(1);
}

// MARK: - Telegram API

const API = `${
  process.env.OBJECTIVE_TELEGRAM_API || "https://api.telegram.org"
}/bot${TOKEN}`;

async function tg(method, body, timeoutMs = 20_000) {
  const res = await fetch(`${API}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const json = await res.json();
  if (!json.ok) {
    const error = new Error(`${method}: ${json.description}`);
    error.code = json.error_code;
    error.retryAfter = json.parameters?.retry_after;
    throw error;
  }
  return json.result;
}

// MARK: - Rendering

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const hashtag = (s) => `#${String(s).replace(/[^\p{L}\p{N}_]+/gu, "_")}`;

function renderText(item, { removed = false } = {}) {
  const lines = [];
  if (removed) {
    lines.push(`🚫 <s>${esc(item.text)}</s>`);
  } else if (item.status === "done") {
    lines.push(`✅ <s>${esc(item.text)}</s>`);
  } else {
    lines.push(`${item.urgent ? "🔴" : "🎯"} <b>${esc(item.text)}</b>`);
  }

  if (item.detail) lines.push(esc(item.detail));

  if (item.status === "open" && item.allowReply) {
    lines.push("<i>Reply to this message with your answer.</i>");
  }

  if (item.answer) lines.push(`\n💬 <b>${esc(item.answer)}</b>`);
  else if (removed) lines.push("\n<i>Withdrawn.</i>");
  else if (item.status === "done") lines.push("\n<i>Done.</i>");

  const meta = [];
  if (item.source) meta.push(hashtag(item.source));
  if (item.urgent && item.status === "open") meta.push("#urgent");
  if (meta.length) lines.push(`\n<i>${esc(meta.join(" "))}</i>`);

  return lines.join("\n");
}

// Inline keyboards survive an edit; force_reply does not, so it is only used
// on the first send.
function inlineKeyboard(item) {
  if (item.status !== "open") return null;
  if (item.choices?.length) {
    const wide = item.choices.some((c) => c.length > 14);
    const buttons = item.choices.map((choice, i) => ({
      text: choice,
      callback_data: `c|${item.id}|${i}`,
    }));
    const rows = [];
    for (let i = 0; i < buttons.length; i += wide ? 1 : 2) {
      rows.push(buttons.slice(i, i + (wide ? 1 : 2)));
    }
    return { inline_keyboard: rows };
  }
  if (item.allowReply) return null;
  return {
    inline_keyboard: [[{ text: "✓ Done", callback_data: `d|${item.id}` }]],
  };
}

function sendMarkup(item) {
  const keyboard = inlineKeyboard(item);
  if (keyboard) return keyboard;
  if (item.status === "open" && item.allowReply) {
    return {
      force_reply: true,
      input_field_placeholder: "Your answer",
      selective: false,
    };
  }
  return undefined;
}

const signature = (item, removed) =>
  createHash("md5")
    .update(
      JSON.stringify([
        renderText(item, { removed }),
        inlineKeyboard(item),
        removed,
      ])
    )
    .digest("hex");

// MARK: - Board writes

function answerItem(id, text) {
  return mutateBoard((state) => {
    const item = state.items.find((i) => i.id === id);
    if (!item || item.status !== "open") return null;
    const now = Date.now() / 1000;
    item.answer = text;
    item.answeredAt = now;
    item.status = "done";
    item.doneAt = now;
    return item;
  });
}

function completeItem(id) {
  return mutateBoard((state) => {
    const item = state.items.find((i) => i.id === id);
    if (!item || item.status !== "open") return null;
    item.status = "done";
    item.doneAt = Date.now() / 1000;
    return item;
  });
}

// MARK: - Sync

let syncing = false;
let syncAgain = false;

async function sync() {
  if (!chatId) return;
  if (syncing) {
    syncAgain = true;
    return;
  }
  syncing = true;
  try {
    await syncOnce();
  } catch (err) {
    log("sync failed:", err.message);
  } finally {
    syncing = false;
    if (syncAgain) {
      syncAgain = false;
      setTimeout(sync, 50);
    }
  }
}

async function syncOnce() {
  const items = readBoard().items;
  const byId = new Map(items.map((i) => [i.id, i]));
  let dirty = false;
  const now = Date.now() / 1000;

  // New items, oldest first so the chat reads in order. A send that failed
  // earlier is retried until MAX_SEND_FAILURES.
  const unsent = items
    .filter((i) => {
      if (i.status !== "open") return false;
      const record = bridgeState.sent[i.id];
      if (!record) return true;
      return !record.messageId && !record.adopted && !record.giveUp;
    })
    .sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0));

  for (const item of unsent) {
    if (isFirstRun && now - (item.createdAt ?? 0) > BACKFILL_MAX_AGE) {
      // Adopt the backlog quietly instead of announcing it.
      bridgeState.sent[item.id] = { adopted: true, status: item.status };
      dirty = true;
      continue;
    }
    try {
      const message = await tg("sendMessage", {
        chat_id: chatId,
        text: renderText(item),
        parse_mode: "HTML",
        reply_markup: sendMarkup(item),
        disable_notification: false,
      });
      bridgeState.sent[item.id] = {
        messageId: message.message_id,
        chatId: message.chat.id,
        sig: signature(item, false),
        status: item.status,
        // Kept so a withdrawn item can still be struck through in the chat.
        snapshot: { text: item.text, detail: item.detail, source: item.source },
      };
      dirty = true;
    } catch (err) {
      const record = bridgeState.sent[item.id] ?? { failures: 0 };
      record.failures = (record.failures ?? 0) + 1;
      if (record.failures >= MAX_SEND_FAILURES) {
        bridgeState.sent[item.id] = { ...record, giveUp: true };
        log(`giving up on "${item.text}":`, err.message);
      }
      dirty = true;
      log("send failed:", err.message);
      if (err.retryAfter) await sleep(err.retryAfter * 1000);
    }
  }

  // Items that changed after they were sent (answered here, checked off in the
  // overlay, or completed by Claude).
  for (const [id, record] of Object.entries(bridgeState.sent)) {
    if (!record.messageId) {
      // Adopted or given-up items carry no message; drop them once gone.
      if (!byId.has(id)) {
        delete bridgeState.sent[id];
        dirty = true;
      }
      continue;
    }
    const item = byId.get(id);
    const removed = !item;
    if (removed && (record.status !== "open" || !record.snapshot)) {
      // Pruned long after it was shown as done, or never described: say nothing.
      delete bridgeState.sent[id];
      dirty = true;
      continue;
    }
    const shown = item ?? { ...record.snapshot, id, status: "open" };
    const sig = signature(shown, removed);
    if (sig === record.sig) {
      if (!record.snapshot && item) {
        record.snapshot = { text: item.text, detail: item.detail, source: item.source };
        dirty = true;
      }
      continue;
    }
    try {
      await tg("editMessageText", {
        chat_id: record.chatId,
        message_id: record.messageId,
        text: renderText(shown, { removed }),
        parse_mode: "HTML",
        reply_markup: inlineKeyboard(removed ? { status: "done" } : shown) ?? undefined,
      });
    } catch (err) {
      // "message is not modified" is harmless; anything else gets retried.
      if (!/not modified/i.test(err.message)) {
        log("edit failed:", err.message);
        continue;
      }
    }
    record.sig = sig;
    record.status = removed ? "removed" : shown.status;
    if (item) {
      record.snapshot = { text: item.text, detail: item.detail, source: item.source };
    }
    dirty = true;
    if (removed) delete bridgeState.sent[id];
  }

  if (dirty) saveBridgeState();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// MARK: - Incoming updates

function itemIdForMessage(messageId) {
  for (const [id, record] of Object.entries(bridgeState.sent)) {
    if (record.messageId === messageId) return id;
  }
  return null;
}

function openItems() {
  return readBoard()
    .items.filter((i) => i.status === "open")
    .sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0));
}

async function say(text, extra = {}) {
  if (!chatId) return;
  await tg("sendMessage", {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    ...extra,
  }).catch((err) => log("reply failed:", err.message));
}

async function handleCallback(query) {
  const [kind, id, index] = String(query.data ?? "").split("|");
  const item = readBoard().items.find((i) => i.id === id);

  if (!item || item.status !== "open") {
    await tg("answerCallbackQuery", {
      callback_query_id: query.id,
      text: "Already answered.",
    }).catch(() => {});
    await sync();
    return;
  }

  let toast = "Done";
  if (kind === "c") {
    const choice = item.choices?.[Number(index)];
    if (choice == null) {
      await tg("answerCallbackQuery", {
        callback_query_id: query.id,
        text: "That choice is gone.",
      }).catch(() => {});
      return;
    }
    answerItem(id, choice);
    toast = choice;
  } else {
    completeItem(id);
  }

  await tg("answerCallbackQuery", {
    callback_query_id: query.id,
    text: `✓ ${toast}`,
  }).catch(() => {});
  await sync();
}

async function handleMessage(message) {
  const text = (message.text ?? "").trim();
  if (!text) return;

  if (text.startsWith("/")) {
    await handleCommand(text, message);
    return;
  }

  // A Telegram reply targets one item directly.
  const repliedTo = message.reply_to_message?.message_id;
  if (repliedTo != null) {
    const id = itemIdForMessage(repliedTo);
    const item = id ? readBoard().items.find((i) => i.id === id) : null;
    if (!item) {
      await say("That message is not on the board any more.");
      return;
    }
    if (item.status !== "open") {
      await say(`Already answered: <b>${esc(item.answer ?? "done")}</b>`);
      return;
    }
    answerItem(id, text);
    await sync();
    return;
  }

  // Otherwise the newest item that asked for text takes it.
  const waiting = openItems()
    .filter((i) => i.allowReply)
    .pop();
  if (waiting) {
    answerItem(waiting.id, text);
    await sync();
    return;
  }

  const open = openItems();
  if (open.length === 1 && !open[0].choices) {
    answerItem(open[0].id, text);
    await sync();
    return;
  }
  await say(
    open.length
      ? "Reply to the message you want to answer, or tap a button."
      : "Nothing is waiting for you. 🎯"
  );
}

async function handleCommand(text, message) {
  const command = text.split(/[\s@]/)[0].toLowerCase();

  if (command === "/start") {
    if (!chatId) {
      chatId = message.chat.id;
      config.chatId = chatId;
      saveConfig();
      log("registered chat", chatId);
    }
    await say(
      "🎯 <b>Objective</b> is connected.\n\n" +
        "New objectives arrive here. Tap a button to decide, or reply to a " +
        "message to answer with text.\n\n" +
        "/list open objectives\n/help what the buttons do"
    );
    await sync();
    return;
  }

  if (command === "/list") {
    const open = openItems();
    if (!open.length) {
      await say("Nothing open. 🎯");
      return;
    }
    const lines = open.map((i) => {
      const mark = i.urgent ? "🔴" : "•";
      const source = i.source ? ` <i>${esc(hashtag(i.source))}</i>` : "";
      return `${mark} ${esc(i.text)}${source}`;
    });
    await say(`<b>${open.length} open</b>\n${lines.join("\n")}`);
    return;
  }

  if (command === "/help") {
    await say(
      "<b>How this works</b>\n" +
        "🎯 a new objective needs you. 🔴 means urgent.\n" +
        "Buttons: tap one and the answer goes straight back.\n" +
        "Text: reply to the message and your text is the answer.\n" +
        "✓ Done: checks a plain objective off.\n\n" +
        "/list open objectives\n/id this chat id"
    );
    return;
  }

  if (command === "/id") {
    await say(`Chat id: <code>${message.chat.id}</code>`);
    return;
  }

  await say("Unknown command. Try /list or /help.");
}

async function handleUpdate(update) {
  const from = update.message?.chat?.id ?? update.callback_query?.message?.chat?.id;
  const isStart = (update.message?.text ?? "").trim().startsWith("/start");

  if (chatId && from != null && String(from) !== String(chatId)) {
    log("ignoring update from chat", from);
    return;
  }
  if (!chatId && !isStart) return;

  if (update.callback_query) await handleCallback(update.callback_query);
  else if (update.message) await handleMessage(update.message);
}

// MARK: - Loops

async function pollLoop() {
  let backoff = 1000;
  for (;;) {
    try {
      const updates = await tg(
        "getUpdates",
        {
          offset: bridgeState.offset || undefined,
          timeout: POLL_TIMEOUT,
          allowed_updates: ["message", "callback_query"],
        },
        (POLL_TIMEOUT + 10) * 1000
      );
      backoff = 1000;
      for (const update of updates) {
        bridgeState.offset = update.update_id + 1;
        saveBridgeState();
        try {
          await handleUpdate(update);
        } catch (err) {
          log("update failed:", err.message);
        }
      }
    } catch (err) {
      if (err.name === "TimeoutError" || err.name === "AbortError") continue;
      log("poll failed:", err.message);
      await sleep(err.retryAfter ? err.retryAfter * 1000 : backoff);
      backoff = Math.min(backoff * 2, 60_000);
    }
  }
}

function watchBoard() {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  let timer = null;
  const bump = () => {
    clearTimeout(timer);
    timer = setTimeout(sync, 150);
  };
  try {
    fs.watch(STATE_DIR, bump);
  } catch (err) {
    log("watch failed, polling only:", err.message);
  }
  setInterval(sync, 5000); // safety net for missed events
}

const me = await tg("getMe").catch((err) => {
  console.error(`Cannot reach Telegram: ${err.message}`);
  process.exit(1);
});

log(`online as @${me.username}`);
if (!chatId) log("send /start to the bot to link this chat");
else log(`sending to chat ${chatId}`);

watchBoard();
await sync();
if (isFirstRun) saveBridgeState();
await pollLoop();
