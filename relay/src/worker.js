// Objective relay: one shared Telegram bot for every user.
//
// Why this exists: a shared bot has one token. That token can never ship inside
// the Mac app, because anybody could read it and then read every user's
// messages. So the token lives here, and Telegram talks to this Worker.
//
// Routing: every Telegram chat gets one Durable Object, named "chat:<id>".
// It holds the chat's items and it is the only writer, so answers are strongly
// consistent and a long poll returns the instant the user taps a button.
//
// Account keys are signed, not stored: ob1.<chatId36>.<epoch>.<hmac>. The
// Worker reads the chat id straight from the key to find the right object, and
// the object verifies the signature. /unlink raises the epoch, which kills every
// key that chat ever handed out.

import { renderText, inlineKeyboard, sendMarkup } from "./render.js";

const MAX_WAIT_SECONDS = 25; // one poll stays well inside any edge timeout
const PAIR_CODE_TTL = 10 * 60 * 1000;
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no I, O, 0, 1

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });

const bytesToHex = (bytes) =>
  [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");

async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(message)
  );
  return bytesToHex(new Uint8Array(signature)).slice(0, 32);
}

// Chat ids stay well inside the safe integer range, so base 36 round-trips.
const accountKeyFor = async (secret, chatId, epoch) =>
  `ob1.${Number(chatId).toString(36)}.${epoch}.${await hmacHex(
    secret,
    `${chatId}:${epoch}`
  )}`;

function parseAccountKey(key) {
  const parts = String(key ?? "").split(".");
  if (parts.length !== 4 || parts[0] !== "ob1") return null;
  const chatId = parseInt(parts[1], 36);
  const epoch = Number(parts[2]);
  if (!Number.isSafeInteger(chatId) || !Number.isInteger(epoch)) return null;
  return { chatId: String(chatId), epoch, mac: parts[3] };
}

function randomCode(length = 8) {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return [...bytes].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
}

// Constant-time enough for a short hex string.
function safeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function telegram(env, method, body) {
  const response = await fetch(
    `${env.TELEGRAM_API ?? "https://api.telegram.org"}/bot${env.BOT_TOKEN}/${method}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }
  );
  const result = await response.json();
  if (!result.ok) throw new Error(`${method}: ${result.description}`);
  return result.result;
}

const chatObject = (env, chatId) =>
  env.BOARD.get(env.BOARD.idFromName(`chat:${chatId}`));

const codeObject = (env, code) =>
  env.BOARD.get(env.BOARD.idFromName(`code:${code}`));

// MARK: - Worker

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/telegram/webhook") {
      if (
        request.headers.get("x-telegram-bot-api-secret-token") !==
        env.WEBHOOK_SECRET
      ) {
        return json({ error: "bad secret" }, 403);
      }
      // Telegram retries on a non-200, which would duplicate messages.
      try {
        await handleUpdate(env, await request.json());
      } catch (err) {
        console.error("update failed", err.message);
      }
      return json({ ok: true });
    }

    if (url.pathname === "/v1/pair" && request.method === "POST") {
      const { code } = await request.json();
      const holder = codeObject(env, String(code ?? "").toUpperCase());
      const claimed = await holder
        .fetch("https://board/claim-code", { method: "POST" })
        .then((r) => r.json());
      if (!claimed.chatId) return json({ error: "unknown or expired code" }, 404);

      const epoch = await chatObject(env, claimed.chatId)
        .fetch("https://board/epoch")
        .then((r) => r.json())
        .then((r) => r.epoch);
      return json({
        account_key: await accountKeyFor(env.KEY_SECRET, claimed.chatId, epoch),
      });
    }

    if (url.pathname.startsWith("/v1/")) {
      const parsed = parseAccountKey(
        (request.headers.get("authorization") ?? "").replace(/^Bearer /, "")
      );
      if (!parsed) return json({ error: "no account key" }, 401);
      parsed.expectedMac = await hmacHex(
        env.KEY_SECRET,
        `${parsed.chatId}:${parsed.epoch}`
      );
      return chatObject(env, parsed.chatId).fetch(
        new Request(`https://board${url.pathname.slice(3)}${url.search}`, {
          method: request.method,
          headers: {
            "content-type": "application/json",
            "x-account": JSON.stringify(parsed),
          },
          body: ["GET", "HEAD"].includes(request.method)
            ? undefined
            : await request.text(),
        })
      );
    }

    if (url.pathname === "/") return json({ ok: true, service: "objective-relay" });
    return json({ error: "not found" }, 404);
  },
};

async function handleUpdate(env, update) {
  const message = update.message;
  const query = update.callback_query;
  const chatId = message?.chat?.id ?? query?.message?.chat?.id;
  if (!chatId) return;

  if (message?.text?.startsWith("/start")) {
    const code = randomCode();
    await codeObject(env, code).fetch("https://board/hold-code", {
      method: "POST",
      body: JSON.stringify({ chatId: String(chatId) }),
    });
    await telegram(env, "sendMessage", {
      chat_id: chatId,
      parse_mode: "HTML",
      text:
        "🎯 <b>Objective</b>\n\nYour pairing code:\n\n" +
        `<code>${code}</code>\n\n` +
        "Run this on your Mac, in the objective repo:\n" +
        `<code>make relay-pair CODE=${code}</code>\n\n` +
        "The code is valid for ten minutes.",
    });
    return;
  }

  if (message?.text === "/unlink") {
    await chatObject(env, chatId).fetch("https://board/unlink", { method: "POST" });
    await telegram(env, "sendMessage", {
      chat_id: chatId,
      text: "Unlinked. Every device key for this chat is now dead. Send /start to pair again.",
    });
    return;
  }

  if (message?.text === "/help") {
    await telegram(env, "sendMessage", {
      chat_id: chatId,
      parse_mode: "HTML",
      text:
        "<b>How this works</b>\n" +
        "🎯 a new objective needs you. 🔴 means urgent.\n" +
        "Buttons: tap one and the answer goes back to the agent.\n" +
        "Text: reply to the message and your text is the answer.\n\n" +
        "/start pair a Mac\n/unlink revoke every paired Mac",
    });
    return;
  }

  await chatObject(env, chatId).fetch("https://board/telegram-update", {
    method: "POST",
    body: JSON.stringify(update),
  });
}

// MARK: - Durable Object

export class Board {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.waiters = new Map(); // item id -> Set of resolve functions
  }

  async fetch(request) {
    const url = new URL(request.url);
    const account = request.headers.get("x-account");

    switch (url.pathname) {
      case "/hold-code": {
        const { chatId } = await request.json();
        await this.state.storage.put("code", { chatId, expires: Date.now() + PAIR_CODE_TTL });
        return json({ ok: true });
      }
      case "/claim-code": {
        const held = await this.state.storage.get("code");
        await this.state.storage.delete("code");
        if (!held || held.expires < Date.now()) return json({});
        return json({ chatId: held.chatId });
      }
      case "/epoch":
        return json({ epoch: (await this.state.storage.get("epoch")) ?? 1 });
      case "/unlink": {
        const epoch = ((await this.state.storage.get("epoch")) ?? 1) + 1;
        await this.state.storage.put("epoch", epoch);
        return json({ ok: true, epoch });
      }
      case "/telegram-update":
        return this.onTelegramUpdate(await request.json());
    }

    // Everything below needs a valid, current account key.
    const denied = await this.verify(account);
    if (denied) return denied;

    switch (url.pathname) {
      case "/items":
        return this.createItem(await request.json());
      case "/item":
        return this.readItem(url.searchParams);
      case "/close":
        return this.closeItem(await request.json());
      default:
        return json({ error: "not found" }, 404);
    }
  }

  async verify(header) {
    if (!header) return json({ error: "no account key" }, 401);
    const parsed = JSON.parse(header);
    const epoch = (await this.state.storage.get("epoch")) ?? 1;
    if (parsed.epoch !== epoch) return json({ error: "key revoked" }, 401);
    if (!safeEqual(parsed.mac, parsed.expectedMac)) {
      return json({ error: "bad signature" }, 401);
    }
    this.chatId = parsed.chatId;
    return null;
  }

  async createItem(body) {
    const item = {
      id: body.id ?? crypto.randomUUID(),
      text: body.text,
      detail: body.detail ?? null,
      choices: body.choices ?? null,
      allowReply: body.allow_reply ?? false,
      urgent: body.urgent ?? false,
      source: body.source ?? null,
      status: "open",
      answer: null,
      createdAt: Date.now(),
      chatId: this.chatId,
    };

    const message = await telegram(this.env, "sendMessage", {
      chat_id: this.chatId,
      text: renderText(item),
      parse_mode: "HTML",
      reply_markup: sendMarkup(item),
      // Explicit, so nobody has to wonder why a phone stayed quiet.
      disable_notification: false,
    });
    item.messageId = message.message_id;

    await this.state.storage.put(`item:${item.id}`, item);
    return json({ ok: true, id: item.id });
  }

  async readItem(params) {
    const id = params.get("id");
    const wait = Math.min(Number(params.get("wait") ?? 0), MAX_WAIT_SECONDS);
    let item = await this.state.storage.get(`item:${id}`);
    if (!item) return json({ error: "unknown item" }, 404);

    if (item.status === "open" && wait > 0) {
      item = await this.waitFor(id, wait);
    }
    return json({
      status: item.status,
      answer: item.answer,
      timed_out: item.status === "open",
    });
  }

  waitFor(id, seconds) {
    return new Promise((resolve) => {
      const waiters = this.waiters.get(id) ?? new Set();
      const finish = async (item) => {
        clearTimeout(timer);
        waiters.delete(finish);
        resolve(item ?? (await this.state.storage.get(`item:${id}`)));
      };
      const timer = setTimeout(() => finish(null), seconds * 1000);
      waiters.add(finish);
      this.waiters.set(id, waiters);
    });
  }

  async settle(item, answer) {
    item.status = "done";
    item.answer = answer ?? item.answer ?? null;
    item.doneAt = Date.now();
    await this.state.storage.put(`item:${item.id}`, item);

    for (const waiter of this.waiters.get(item.id) ?? []) waiter(item);
    this.waiters.delete(item.id);

    if (item.messageId) {
      await telegram(this.env, "editMessageText", {
        chat_id: item.chatId ?? this.chatId,
        message_id: item.messageId,
        text: renderText(item),
        parse_mode: "HTML",
        reply_markup: inlineKeyboard(item) ?? undefined,
      }).catch(() => {});
    }
    return item;
  }

  // The user answered in the Mac overlay, so the chat message must catch up.
  async closeItem({ id, answer }) {
    const item = await this.state.storage.get(`item:${id}`);
    if (!item) return json({ error: "unknown item" }, 404);
    if (item.status === "open") await this.settle(item, answer);
    return json({ ok: true });
  }

  async onTelegramUpdate(update) {
    this.chatId = String(
      update.message?.chat?.id ?? update.callback_query?.message?.chat?.id
    );

    if (update.callback_query) {
      const query = update.callback_query;
      const [kind, id, index] = String(query.data ?? "").split("|");
      const item = await this.state.storage.get(`item:${id}`);
      let toast = "Already answered.";

      if (item && item.status === "open") {
        const choice = kind === "c" ? item.choices?.[Number(index)] : null;
        await this.settle(item, choice);
        toast = `✓ ${choice ?? "Done"}`;
      }
      await telegram(this.env, "answerCallbackQuery", {
        callback_query_id: query.id,
        text: toast,
      }).catch(() => {});
      return json({ ok: true });
    }

    const text = update.message?.text?.trim();
    if (!text) return json({ ok: true });

    const open = (await this.openItems()).sort((a, b) => a.createdAt - b.createdAt);
    const repliedTo = update.message.reply_to_message?.message_id;
    const target = repliedTo
      ? open.find((i) => i.messageId === repliedTo)
      : open.filter((i) => i.allowReply).pop() ??
        (open.length === 1 && !open[0].choices ? open[0] : null);

    if (!target) {
      await telegram(this.env, "sendMessage", {
        chat_id: this.chatId,
        text: open.length
          ? "Reply to the message you want to answer, or tap a button."
          : "Nothing is waiting for you. 🎯",
      }).catch(() => {});
      return json({ ok: true });
    }

    await this.settle(target, text);
    return json({ ok: true });
  }

  async openItems() {
    const stored = await this.state.storage.list({ prefix: "item:" });
    return [...stored.values()].filter((i) => i.status === "open");
  }
}
