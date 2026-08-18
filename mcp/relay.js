// Talks to the shared-bot relay, when the user has paired one.
//
// The local state file stays the source of truth for the overlay. The relay is
// a second front end: items are pushed to it, and answers flow back from it.
// Whichever side answers first wins, and the other side is told.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const STATE_DIR =
  process.env.OBJECTIVE_STATE_DIR ||
  path.join(os.homedir(), "Library", "Application Support", "Objective");
const CONFIG_FILE = path.join(STATE_DIR, "relay.json");
const POLL_WAIT = 25; // seconds the relay holds one request open

export function relayConfig() {
  if (process.env.OBJECTIVE_RELAY_URL && process.env.OBJECTIVE_RELAY_KEY) {
    return {
      url: process.env.OBJECTIVE_RELAY_URL,
      accountKey: process.env.OBJECTIVE_RELAY_KEY,
    };
  }
  try {
    const config = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
    return config.url && config.accountKey ? config : null;
  } catch {
    return null;
  }
}

function saveConfig(config) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const tmp = `${CONFIG_FILE}.tmp-relay`;
  fs.writeFileSync(tmp, JSON.stringify(config, null, 2));
  fs.renameSync(tmp, CONFIG_FILE);
}

async function call(relay, path, { method = "GET", body, signal } = {}) {
  const response = await fetch(`${relay.url}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${relay.accountKey}`,
    },
    body: body ? JSON.stringify(body) : undefined,
    signal,
  });
  if (!response.ok) {
    throw new Error(`relay ${path}: ${response.status} ${await response.text()}`);
  }
  return response.json();
}

// Exchanges a pairing code from the bot for this Mac's account key.
export async function pair(url, code) {
  const base = url.replace(/\/$/, "");
  const response = await fetch(`${base}/v1/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code }),
  });
  const result = await response.json();
  if (!response.ok || !result.account_key) {
    throw new Error(result.error ?? `pairing failed (${response.status})`);
  }
  saveConfig({ url: base, accountKey: result.account_key });
  return { url: base, accountKey: result.account_key };
}

export const pushItem = (relay, item) =>
  call(relay, "/v1/items", {
    method: "POST",
    body: {
      id: item.id,
      text: item.text,
      detail: item.detail,
      choices: item.choices,
      allow_reply: item.allowReply,
      urgent: item.urgent,
      source: item.source,
    },
  });

export const closeItem = (relay, id, answer) =>
  call(relay, "/v1/close", { method: "POST", body: { id, answer } });

// Resolves with the user's answer, or never, if the caller aborts first.
export async function waitForAnswer(relay, id, signal) {
  for (;;) {
    if (signal.aborted) return new Promise(() => {});
    try {
      const result = await call(relay, `/v1/item?id=${id}&wait=${POLL_WAIT}`, {
        signal: AbortSignal.any([signal, AbortSignal.timeout((POLL_WAIT + 10) * 1000)]),
      });
      if (result.status === "done") return result.answer ?? null;
    } catch (err) {
      if (signal.aborted) return new Promise(() => {});
      // A dropped connection is normal for a long poll. Slow down on real errors.
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}
