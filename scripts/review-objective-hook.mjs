#!/usr/bin/env node
// Claude Code Stop hook.
// An agent that delivered work must not end its turn silently. If it changed
// files but never put anything on the board, this hook blocks the stop once and
// tells it to add a review item. The second stop always goes through, so the
// agent can never get stuck in a loop.
//
// Register it in ~/.claude/settings.json under "hooks" -> "Stop".

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const BOARD_WINDOW_MINUTES = 45; // an item this fresh counts as "the agent asked"
const WORK_WINDOW_MINUTES = 25; // a file this fresh counts as "work happened"
const SKIP = new Set([
  "node_modules",
  ".git",
  ".build",
  "build",
  "dist",
  ".next",
  "vendor",
  "Pods",
  ".venv",
  "target",
]);

const allow = () => process.exit(0);

function readStdin() {
  try {
    return JSON.parse(fs.readFileSync(0, "utf8"));
  } catch {
    return {};
  }
}

function boardTouchedRecently(source) {
  const stateFile = path.join(
    process.env.OBJECTIVE_STATE_DIR ||
      path.join(os.homedir(), "Library", "Application Support", "Objective"),
    "state.json"
  );
  let items;
  try {
    items = JSON.parse(fs.readFileSync(stateFile, "utf8")).items;
  } catch {
    return false;
  }
  const cutoff = Date.now() / 1000 - BOARD_WINDOW_MINUTES * 60;
  return items.some(
    (i) =>
      i.source === source &&
      Math.max(i.createdAt ?? 0, i.doneAt ?? 0, i.answeredAt ?? 0) > cutoff
  );
}

// Cheap and shallow on purpose: a hook must not slow a turn down.
function workHappened(root) {
  const cutoff = Date.now() - WORK_WINDOW_MINUTES * 60 * 1000;
  const stack = [[root, 0]];
  let checked = 0;

  while (stack.length) {
    const [dir, depth] = stack.pop();
    if (depth > 4) continue;
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (entry.name.startsWith(".") || SKIP.has(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        stack.push([full, depth + 1]);
        continue;
      }
      if (++checked > 4000) return false;
      try {
        if (fs.statSync(full).mtimeMs > cutoff) return true;
      } catch {}
    }
  }
  return false;
}

const input = readStdin();
if (input.stop_hook_active) allow();

const cwd = input.cwd || process.cwd();
const source = path.basename(cwd);

if (boardTouchedRecently(source)) allow();
if (!workHappened(cwd)) allow();

console.error(
  `You changed files in ${source} but put nothing on the user's Objective board ` +
    "in this turn. The user wants one board item whenever you deliver work or " +
    "need a decision. Add it now with objective_add: a short review item " +
    "(wait: false) for finished work, or a real question with `choices` if you " +
    "need an answer. Then stop again."
);
process.exit(2);
