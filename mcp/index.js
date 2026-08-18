#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";

const STATE_DIR = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "Objective"
);
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

const server = new McpServer({ name: "objective", version: "1.0.0" });

server.registerTool(
  "objective_add",
  {
    title: "Add objective",
    description:
      "Add an item to the user's always-on-top Objective overlay board. " +
      "Use this when you need the user's input, decision, or action. " +
      "Give `choices` for a quick decision (the user clicks one), or set " +
      "`allow_reply` for a free-text answer. Then call objective_wait with " +
      "the returned id to get the user's answer. Returns the new item's id.",
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
    },
  },
  async ({ text, detail, choices, allow_reply, urgent, source }) => {
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
    return textResult({ ok: true, item: itemSummary(item) });
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
      "Block until the user answers or checks the item off (or it is removed), " +
      "then return its final status and answer. " +
      "Polls the board every 2 seconds. Default timeout 240 seconds.",
    inputSchema: {
      id: z.string().describe("Item id to wait for"),
      timeout_seconds: z
        .number()
        .int()
        .min(5)
        .max(3600)
        .optional()
        .describe("Give up after this many seconds (default 240)"),
    },
  },
  async ({ id, timeout_seconds }) => {
    const deadline = Date.now() + (timeout_seconds ?? 240) * 1000;
    while (Date.now() < deadline) {
      const item = readState().items.find((i) => i.id === id);
      if (!item) return textResult({ result: "removed" });
      if (item.status === "done")
        return textResult({ result: "done", answer: item.answer ?? null });
      await new Promise((r) => setTimeout(r, 2000));
    }
    return textResult({ result: "timeout", note: "Item is still open." });
  }
);

await server.connect(new StdioServerTransport());
