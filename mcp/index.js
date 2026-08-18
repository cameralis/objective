#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";

const STATE_DIR =
  process.env.OBJECTIVE_STATE_DIR ||
  path.join(os.homedir(), "Library", "Application Support", "Objective");
const STATE_FILE = path.join(STATE_DIR, "state.json");
const APP_PATH =
  process.env.OBJECTIVE_APP ||
  path.join(os.homedir(), "Applications", "Objective.app");

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
    answer: item.answer ?? null,
  };
}

function textResult(value) {
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }] };
}

// Block until the user answers, checks the item off, or removes it.
// The state directory is watched, so a click comes back in milliseconds; the
// one-second poll is only a safety net for missed file events.
async function waitForItem(id, timeoutSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  let wake = null;
  let watcher = null;
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    watcher = fs.watch(STATE_DIR, () => wake?.());
  } catch {
    // Fall back to polling only.
  }
  try {
    for (;;) {
      const item = readState().items.find((i) => i.id === id);
      if (!item) return { result: "removed" };
      if (item.status !== "open") {
        return {
          result: "done",
          answer: item.answer ?? null,
          answered: item.answer != null,
        };
      }
      const left = deadline - Date.now();
      if (left <= 0) {
        return {
          result: "timeout",
          note: "Item is still open. Call objective_wait with the same id to keep waiting.",
        };
      }
      await new Promise((resolve) => {
        const timer = setTimeout(finish, Math.min(1000, left));
        wake = finish;
        function finish() {
          clearTimeout(timer);
          wake = null;
          resolve();
        }
      });
    }
  } finally {
    watcher?.close();
  }
}

const server = new McpServer({ name: "objective", version: "1.0.0" });

server.registerTool(
  "objective_add",
  {
    title: "Add objective",
    description:
      "Ask the user something on their Objective board (a macOS overlay and, " +
      "if linked, Telegram). Use this when you need their input, decision, or " +
      "an action only they can do. Give `choices` for a quick decision, or " +
      "`allow_reply` for a free-text answer. " +
      "THIS CALL BLOCKS until the user answers and returns their answer, so " +
      "you get it the moment they click. Do not poll and do not ask the user " +
      "to tell you when they are done. Pass `wait: false` only for a note the " +
      "user can handle later, when nothing you do next depends on it.",
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
      timeout_seconds: z
        .number()
        .int()
        .min(5)
        .max(3600)
        .optional()
        .describe("How long to block, in seconds (default 1800)"),
    },
  },
  async ({
    text,
    detail,
    choices,
    allow_reply,
    urgent,
    source,
    wait,
    timeout_seconds,
  }) => {
    const item = {
      id: randomUUID(),
      text,
      detail,
      status: "open",
      createdAt: Date.now() / 1000,
      choices,
      allowReply: allow_reply ?? false,
      urgent: urgent ?? false,
      source: source ?? path.basename(process.cwd()),
    };
    mutate((s) => s.items.push(item));
    ensureAppRunning();

    if (wait === false) {
      return textResult({ ok: true, item: itemSummary(item) });
    }

    const outcome = await waitForItem(item.id, timeout_seconds ?? 1800);
    return textResult({ ok: true, id: item.id, ...outcome });
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
    description: "Mark an item done. Use when the request is resolved.",
    inputSchema: { id: z.string().describe("Item id") },
  },
  async ({ id }) => {
    let found = false;
    mutate((s) => {
      const item = s.items.find((i) => i.id === id);
      if (item && item.status === "open") {
        item.status = "done";
        item.doneAt = Date.now() / 1000;
        found = true;
      }
    });
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
    mutate((s) => {
      s.items =
        scope === "all" ? [] : s.items.filter((i) => i.status === "open");
    });
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
        .min(5)
        .max(3600)
        .optional()
        .describe("Give up after this many seconds (default 1800)"),
    },
  },
  async ({ id, timeout_seconds }) =>
    textResult(await waitForItem(id, timeout_seconds ?? 1800))
);

await server.connect(new StdioServerTransport());
