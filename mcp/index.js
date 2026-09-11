#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import * as relay from "./relay.js";
import { captureOrigin, markWaiting, clearWaiting } from "./origin.js";
import { readPresence, settle } from "./presence.js";
import { until } from "./watch.js";

const STATE_DIR =
  process.env.OBJECTIVE_STATE_DIR ||
  path.join(os.homedir(), "Library", "Application Support", "Objective");
const STATE_FILE = path.join(STATE_DIR, "state.json");
const APP_PATH =
  process.env.OBJECTIVE_APP ||
  path.join(os.homedir(), "Applications", "Objective.app");

const AT_MAC = "At the Mac";
const READY = "Ready";
const SKIP = "Skip";
const AT_MAC_NOTE = "🖥 Waits for you at the Mac. The agent goes on when you are back.";

function readState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
  } catch {
    return { rev: 0, items: [] };
  }
}

function writeState(state) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const tmp = path.join(STATE_DIR, "state.json.tmp-mcp");
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, STATE_FILE);
}

function mutate(change) {
  const state = readState();
  change(state);
  state.rev += 1;
  writeState(state);
  return state;
}

const isOpen = (id) => readState().items.some((i) => i.id === id && i.status === "open");

const watchState = (check, options) => until(STATE_DIR, check, options);

function ensureAppRunning() {
  if (fs.existsSync(APP_PATH)) {
    execFile("open", ["-g", APP_PATH], () => {});
  }
}

function itemSummary(item) {
  return {
    id: item.id,
    text: item.text,
    detail: item.detail ?? null,
    status: item.status,
    urgent: item.urgent ?? false,
    source: item.source ?? null,
    choices: item.choices ?? null,
    allowReply: item.allowReply ?? false,
    atMac: item.atMac ?? false,
    answer: item.answer ?? null,
  };
}

function textResult(value) {
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }] };
}

// Block until the user answers, checks the item off, or removes it.
// `signal` fires when the client stops the tool call or the session ends; the
// wait must end there too, or the question outlives the agent that asked it.
async function waitForItem(id, timeoutSeconds, signal) {
  // 0 means wait for as long as the session lives.
  const deadline =
    timeoutSeconds > 0 ? Date.now() + timeoutSeconds * 1000 : Infinity;
  const outcome = await watchState(
    () => {
      const item = readState().items.find((i) => i.id === id);
      if (!item) return { result: "removed" };
      if (item.status !== "open") {
        return {
          result: "done",
          answer: item.answer ?? null,
          answered: item.answer != null,
        };
      }
      if (Date.now() >= deadline) {
        return {
          result: "timeout",
          note: "Item is still open. Call objective_wait with the same id to keep waiting.",
        };
      }
    },
    { signal, deadline }
  );
  return outcome ?? { result: "cancelled" };
}

// `node mcp/index.js --pair CODE [--url https://relay.example.workers.dev]`
if (process.argv.includes("--pair")) {
  const code = process.argv[process.argv.indexOf("--pair") + 1];
  const urlFlag = process.argv.indexOf("--url");
  const url =
    (urlFlag >= 0 ? process.argv[urlFlag + 1] : null) ??
    process.env.OBJECTIVE_RELAY_URL ??
    relay.relayConfig()?.url;
  if (!code || !url) {
    console.error(
      "Usage: node mcp/index.js --pair <CODE> --url <relay url>\n" +
        "Send /start to the bot in Telegram to get a code."
    );
    process.exit(1);
  }
  try {
    const link = await relay.pair(url, code.trim().toUpperCase());
    console.log(`Paired with ${link.url}. Telegram now mirrors your board.`);
    process.exit(0);
  } catch (err) {
    console.error(`Pairing failed: ${err.message}`);
    process.exit(1);
  }
}

function answerLocally(id, answer) {
  mutate((s) => {
    const item = s.items.find((i) => i.id === id);
    if (!item || item.status !== "open") return;
    const now = Date.now() / 1000;
    if (answer != null) {
      item.answer = answer;
      item.answeredAt = now;
    }
    item.status = "done";
    item.doneAt = now;
  });
}

// Closing anywhere closes everywhere: the chat message follows the board.
function closeOnRelay(id, answer) {
  const link = relay.relayConfig();
  if (link) relay.closeItem(link, id, answer ?? null).catch(() => {});
}

// The agent that asked can disappear: the user stops the tool call, or the
// session ends. Nobody is left to read the answer, so the question goes away
// instead of sitting on the board as a blocked agent forever. An item the user
// answered in the same moment is already done, and stays.
function dropAbandoned(id) {
  let dropped = false;
  mutate((s) => {
    const before = s.items.length;
    s.items = s.items.filter((i) => !(i.id === id && i.status === "open"));
    dropped = s.items.length < before;
  });
  if (dropped) closeOnRelay(id, null);
  return dropped;
}

// Questions this process still waits on, so a kill can clean up after itself.
const pending = new Map();

let cleanedUp = false;
function dropAllPending() {
  if (cleanedUp) return 0;
  cleanedUp = true;
  let dropped = 0;
  for (const [id, origin] of pending) {
    if (dropAbandoned(id)) dropped += 1;
    clearWaiting(origin);
  }
  pending.clear();
  return dropped;
}

for (const name of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(name, () => {
    // The board is written before we go. The short delay is only so the
    // Telegram message can be closed as well.
    const dropped = dropAllPending();
    if (dropped) setTimeout(() => process.exit(0), 300);
    else process.exit(0);
  });
}
process.on("exit", dropAllPending);

// MARK: - Telegram, when the user is away

// Items this process delivers, by id. Each resolves true once the item is on
// Telegram, and false when it closed first.
const deliveries = new Map();

// Telegram is the push notification for when the user is away. An item goes
// there when the user is away as it arrives, when an unsure user lets its
// banner pass, or when the user leaves while it is still open.
function startDelivery(item) {
  const link = relay.relayConfig();
  const delivered = link ? deliverWhenAway(link, item) : Promise.resolve(false);
  deliveries.set(item.id, delivered);
  return link ? "board, and Telegram when the user is away" : "board";
}

async function deliverWhenAway(link, item) {
  const open = () => isOpen(item.id);
  for (;;) {
    const presence = await settle({ isOpen: open });
    if (presence === "closed") return false;
    if (presence !== "present") return pushToTelegram(link, item, open);
    const change = await watchState(() => {
      if (!open()) return "closed";
      if (readPresence()?.state !== "present") return "left";
    });
    if (change === "closed") return false;
  }
}

// A failed push must not leave an away user without the message.
async function pushToTelegram(link, item, open) {
  const detail = item.atMac
    ? [AT_MAC_NOTE, item.detail].filter(Boolean).join("\n")
    : item.detail;
  for (;;) {
    try {
      await relay.pushItem(link, { ...item, detail });
      break;
    } catch (err) {
      console.error(`Telegram push failed: ${err.message}`);
      await new Promise((resolve) => setTimeout(resolve, 10_000));
      if (!open()) return false;
    }
  }
  // An answer that came in during the push found no message to close.
  if (!open()) {
    const stored = readState().items.find((i) => i.id === item.id);
    relay.closeItem(link, item.id, stored?.answer ?? null).catch(() => {});
  }
  return true;
}

// Waits on the overlay and, once the item is there, on Telegram. The first
// answer wins, and the other side is brought up to date.
async function waitForAnswer(id, signal, waitLocally) {
  const link = relay.relayConfig();
  if (!link) return waitLocally(signal);

  const controller = new AbortController();
  const stopRemote = () => controller.abort();
  signal?.addEventListener("abort", stopRemote);
  // An item from before this process started may already be on Telegram.
  const delivered = deliveries.get(id) ?? Promise.resolve(true);
  const remote = delivered
    .then((onTelegram) =>
      onTelegram ? relay.waitForAnswer(link, id, controller.signal) : new Promise(() => {})
    )
    .then((answer) => ({ from: "telegram", answer }));
  const local = waitLocally(signal).then((outcome) => ({
    from: "board",
    outcome,
  }));

  const winner = await Promise.race([remote, local]);
  controller.abort();
  signal?.removeEventListener("abort", stopRemote);

  if (winner.from === "telegram") {
    answerLocally(id, winner.answer);
    return {
      result: "done",
      answer: winner.answer,
      answered: winner.answer != null,
      via: "telegram",
    };
  }

  if (winner.outcome.result === "done") {
    relay.closeItem(link, id, winner.outcome.answer).catch(() => {});
  }
  return winner.outcome;
}

// MARK: - At the Mac

// A freshly opened app needs a moment for its first reading.
async function firstReading(signal) {
  if (!fs.existsSync(APP_PATH)) return null;
  const deadline = Date.now() + 5000;
  const presence = await watchState(
    () => readPresence() ?? (Date.now() >= deadline ? null : undefined),
    { signal, deadline }
  );
  return presence ?? null;
}

// The user is back. The board and the chat both close the item, and the app
// plays its "at the Mac now" banner once.
function markReady(id) {
  let closed = false;
  mutate((s) => {
    const item = s.items.find((i) => i.id === id);
    if (!item) return;
    const now = Date.now() / 1000;
    if (item.status === "open") {
      item.status = "done";
      item.answer = AT_MAC;
      item.answeredAt = now;
      item.doneAt = now;
      closed = true;
    }
    item.readyAt = now;
  });
  if (closed) closeOnRelay(id, AT_MAC);
}

// Waits for the user to be at the Mac, not for an answer. A Touch ID or
// password prompt that nobody sees times out, so the agent holds here while
// the user is away, and the item reaches Telegram in the meantime.
async function askAtMac({ text, detail, urgent, source, timeout_seconds }, extra) {
  const signal = extra?.signal;
  ensureAppRunning();
  const presence = readPresence() ?? (await firstReading(signal));
  const origin = captureOrigin();
  const startedAt = Date.now() / 1000;
  const item = {
    id: randomUUID(),
    text,
    detail,
    status: "open",
    createdAt: startedAt,
    // Without the app nobody can tell, so the user says it with a button.
    choices: presence ? [SKIP] : [READY, SKIP],
    allowReply: false,
    urgent: urgent ?? false,
    source: source ?? origin.project,
    origin,
    atMac: true,
  };

  if (presence?.state === "present") {
    Object.assign(item, {
      status: "done",
      answer: AT_MAC,
      answeredAt: startedAt,
      doneAt: startedAt,
      readyAt: startedAt,
    });
    mutate((s) => s.items.push(item));
    return textResult({
      ok: true,
      id: item.id,
      result: "present",
      waited_seconds: 0,
      note: "The user is at the Mac. Start the step now.",
    });
  }

  Object.assign(item, { waiting: true, waitingSince: startedAt });
  mutate((s) => s.items.push(item));
  const delivery = startDelivery(item);
  markWaiting(origin);
  pending.set(item.id, origin);

  const deadline =
    timeout_seconds > 0 ? Date.now() + timeout_seconds * 1000 : Infinity;
  const waitLocally = async (localSignal) =>
    (await watchState(
      () => {
        const stored = readState().items.find((i) => i.id === item.id);
        if (!stored) return { result: "removed" };
        if (stored.status !== "open") return { result: "done", answer: stored.answer ?? null };
        if (readPresence()?.state === "present") return { result: "present" };
        if (Date.now() >= deadline) return { result: "timeout" };
      },
      { signal: localSignal, deadline }
    )) ?? { result: "cancelled" };

  try {
    const outcome = await waitForAnswer(item.id, signal, waitLocally);
    const waited = Math.round(Date.now() / 1000 - startedAt);

    if (outcome.result === "cancelled") {
      dropAbandoned(item.id);
      return textResult({ ok: false, id: item.id, result: "cancelled" });
    }
    if (outcome.result === "present" || outcome.answer === READY) {
      markReady(item.id);
      return textResult({
        ok: true,
        id: item.id,
        result: "present",
        waited_seconds: waited,
        delivery,
        note: "The user is at the Mac now. Start the step now.",
      });
    }
    if (outcome.result === "timeout") {
      dropAbandoned(item.id);
      return textResult({
        ok: true,
        id: item.id,
        result: "timeout",
        waited_seconds: waited,
        note: "The user did not come back to the Mac in time. Do not start the step. Report it as not done.",
      });
    }
    return textResult({
      ok: true,
      id: item.id,
      result: "skipped",
      answer: outcome.answer ?? null,
      waited_seconds: waited,
      note: "The user skipped this step. Do not start it. Report it as not done.",
    });
  } finally {
    pending.delete(item.id);
    if (signal?.aborted) dropAbandoned(item.id);
    mutate((s) => {
      const stored = s.items.find((i) => i.id === item.id);
      if (stored) stored.waiting = false;
    });
    clearWaiting(origin);
  }
}

// MARK: - Tools

const server = new McpServer({ name: "objective", version: "1.0.0" });

server.registerTool(
  "objective_add",
  {
    title: "Add objective",
    description:
      "Ask the user something on their Objective board (a macOS overlay and, " +
      "while the user is away from the Mac, Telegram). Use it ONLY when you " +
      "are blocked, and only for " +
      "the two kinds of ask that fit in one line: a PERMISSION you lack " +
      "(publish, send, delete, spend), or a FACT only the user holds (which " +
      "name, is it paid). A judgement call about design, architecture, or " +
      "tradeoffs does NOT belong here: ask that in the conversation, where you " +
      "can explain. Never post status or 'review my work' notices. " +
      "Give `choices` for the options, and add `allow_reply` so the user can " +
      "answer something you did not list. " +
      "THIS CALL BLOCKS with no deadline and returns the user's answer, so " +
      "you get it the moment they click, even hours later. The client moves " +
      "the call to the background after about two minutes and tells you when " +
      "it finishes, so waiting costs you nothing. Do not poll and do not ask " +
      "the user to tell you when they are done. Pass `wait: false` only for a " +
      "note the user can handle later, when nothing you do next depends on it. " +
      "For a step only the user can do AT THE MAC (Touch ID, a sudo or " +
      "password prompt, a system dialog, a cable), pass `at_mac: true` BEFORE " +
      "you start that step. The call returns `present` when the user is at " +
      "the Mac: start the step at once. While the user is away it waits and " +
      "reaches them on Telegram, so do your other work first. `skipped` or " +
      "`timeout` means do not start the step.",
    inputSchema: {
      text: z.string().describe("Short objective text shown on the board"),
      detail: z
        .string()
        .optional()
        .describe("Optional one-line extra context shown under the text"),
      choices: z
        .array(z.string())
        .min(2)
        .max(4)
        .optional()
        .describe(
          "2-4 short answer buttons; clicking one answers and completes the item"
        ),
      allow_reply: z
        .boolean()
        .optional()
        .describe(
          "Show a free-text reply field; submitting answers and completes the item"
        ),
      urgent: z
        .boolean()
        .optional()
        .describe("Mark urgent: red styling, stronger sound, sorts to the top"),
      source: z
        .string()
        .optional()
        .describe(
          "Short label of who is asking, e.g. the project or repo name. " +
            "Defaults to the current directory name."
        ),
      wait: z
        .boolean()
        .optional()
        .describe(
          "Block until the user answers and return the answer (default true)"
        ),
      at_mac: z
        .boolean()
        .optional()
        .describe(
          "The step needs the user physically at the Mac (Touch ID, a password " +
            "prompt, a dialog). Waits until the user is at the Mac and returns " +
            "`present`, or `skipped`. Ignores `choices`, `allow_reply`, and `wait`."
        ),
      timeout_seconds: z
        .number()
        .int()
        .min(0)
        .max(604800)
        .optional()
        .describe(
          "How long to block, in seconds. 0 waits with no deadline. " +
            "Default 0: the user may answer hours later, and the answer still " +
            "reaches you."
        ),
    },
  },
  async (
    { text, detail, choices, allow_reply, urgent, source, wait, at_mac, timeout_seconds },
    extra
  ) => {
    if (at_mac) {
      return askAtMac({ text, detail, urgent, source, timeout_seconds }, extra);
    }

    const origin = captureOrigin();
    const item = {
      id: randomUUID(),
      text,
      detail,
      status: "open",
      createdAt: Date.now() / 1000,
      choices,
      allowReply: allow_reply ?? false,
      urgent: urgent ?? false,
      source: source ?? origin.project,
      origin,
    };
    mutate((s) => s.items.push(item));
    ensureAppRunning();
    const delivery = startDelivery(item);

    if (wait === false) {
      return textResult({ ok: true, item: itemSummary(item), delivery });
    }

    // While the agent is blocked, the board shows it as blocked and the
    // agent's own terminal tab carries the marker.
    mutate((s) => {
      const stored = s.items.find((i) => i.id === item.id);
      if (stored) {
        stored.waiting = true;
        stored.waitingSince = Date.now() / 1000;
      }
    });
    markWaiting(origin);
    pending.set(item.id, origin);

    const signal = extra?.signal;
    try {
      const outcome = await waitForAnswer(item.id, signal, (s) =>
        waitForItem(item.id, timeout_seconds ?? 0, s)
      );
      if (outcome.result === "cancelled") {
        dropAbandoned(item.id);
        return textResult({ ok: false, id: item.id, result: "cancelled" });
      }
      return textResult({ ok: true, id: item.id, delivery, ...outcome });
    } finally {
      pending.delete(item.id);
      if (signal?.aborted) dropAbandoned(item.id);
      mutate((s) => {
        const stored = s.items.find((i) => i.id === item.id);
        if (stored) stored.waiting = false;
      });
      clearWaiting(origin);
    }
  }
);

server.registerTool(
  "objective_presence",
  {
    title: "User presence",
    description:
      "Whether the user is at the Mac now: `present`, `unsure`, or `away`, " +
      "with the reason and how long it has held. Use it to plan the order of " +
      "your work. To wait for the user at the Mac, call objective_add with " +
      "`at_mac: true` instead of polling this.",
    inputSchema: {},
  },
  async () => {
    const presence = readPresence();
    if (!presence) {
      return textResult({
        state: "unknown",
        note: "The Objective app does not run, so nobody knows where the user is.",
      });
    }
    return textResult({
      state: presence.state,
      reason: presence.reason,
      for_seconds: Math.max(0, Math.round(Date.now() / 1000 - presence.since)),
      locked: presence.locked,
      chosen_in_menu: presence.override ?? null,
    });
  }
);

server.registerTool(
  "objective_list",
  {
    title: "List objectives",
    description:
      "List items on the Objective board. By default only open items.",
    inputSchema: {
      include_done: z
        .boolean()
        .optional()
        .describe("Also include completed items (default false)"),
    },
  },
  async ({ include_done }) => {
    const state = readState();
    const items = state.items
      .filter((i) => include_done || i.status === "open")
      .map(itemSummary);
    return textResult({ items });
  }
);

server.registerTool(
  "objective_complete",
  {
    title: "Complete objective",
    description:
      "Mark an item done. Use it when the request is resolved, and ALWAYS " +
      "when the user answers you in chat instead of on the board: pass their " +
      "answer so the board matches what they said. Never leave an item open " +
      "that the user already answered.",
    inputSchema: {
      id: z.string().describe("Item id"),
      answer: z
        .string()
        .optional()
        .describe("What the user answered, if they answered in chat"),
    },
  },
  async ({ id, answer }) => {
    let found = false;
    mutate((s) => {
      const item = s.items.find((i) => i.id === id);
      if (item && item.status === "open") {
        const now = Date.now() / 1000;
        if (answer != null) {
          item.answer = answer;
          item.answeredAt = now;
        }
        item.status = "done";
        item.doneAt = now;
        found = true;
      }
    });
    // The chat message must catch up when the answer arrived somewhere else.
    if (found) closeOnRelay(id, answer);
    return textResult({ ok: found });
  }
);

server.registerTool(
  "objective_remove",
  {
    title: "Remove objective",
    description: "Remove an item from the board entirely.",
    inputSchema: { id: z.string().describe("Item id") },
  },
  async ({ id }) => {
    let found = false;
    mutate((s) => {
      const before = s.items.length;
      s.items = s.items.filter((i) => i.id !== id);
      found = s.items.length < before;
    });
    if (found) closeOnRelay(id, null);
    return textResult({ ok: found });
  }
);

server.registerTool(
  "objective_clear",
  {
    title: "Clear objectives",
    description: "Clear the board. scope 'done' removes completed items, scope 'all' removes everything.",
    inputSchema: {
      scope: z.enum(["done", "all"]).describe("What to clear"),
    },
  },
  async ({ scope }) => {
    let removed = [];
    mutate((s) => {
      const gone = scope === "all" ? s.items : s.items.filter((i) => i.status !== "open");
      removed = gone.map((i) => i.id);
      s.items =
        scope === "all" ? [] : s.items.filter((i) => i.status === "open");
    });
    for (const id of removed) closeOnRelay(id, null);
    return textResult({ ok: true });
  }
);

server.registerTool(
  "objective_wait",
  {
    title: "Wait for objective",
    description:
      "Block until the user answers an item you added earlier with " +
      "`wait: false`, or keep waiting after a timeout. Returns the moment the " +
      "user clicks. objective_add already waits by default, so you rarely " +
      "need this.",
    inputSchema: {
      id: z.string().describe("Item id to wait for"),
      timeout_seconds: z
        .number()
        .int()
        .min(0)
        .max(604800)
        .optional()
        .describe("Give up after this many seconds. 0 (default) never gives up."),
    },
  },
  async ({ id, timeout_seconds }, extra) =>
    textResult(
      await waitForAnswer(id, extra?.signal, (s) => waitForItem(id, timeout_seconds ?? 0, s))
    )
);

await server.connect(new StdioServerTransport());
