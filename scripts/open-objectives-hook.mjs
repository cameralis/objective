#!/usr/bin/env node
// Claude Code UserPromptSubmit hook.
// Tells the agent which board items are still open, so that an answer typed in
// chat closes the item too. The user should never have to click twice.
//
// Register it in ~/.claude/settings.json:
//   "hooks": { "UserPromptSubmit": [ { "hooks": [
//     { "type": "command", "command": "node <repo>/scripts/open-objectives-hook.mjs" }
//   ] } ] }

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

try {
  const stateFile = path.join(
    process.env.OBJECTIVE_STATE_DIR ||
      path.join(os.homedir(), "Library", "Application Support", "Objective"),
    "state.json"
  );
  const items = JSON.parse(fs.readFileSync(stateFile, "utf8")).items.filter(
    (i) => i.status === "open"
  );

  if (items.length) {
    const lines = items.map((i) => {
      const options = i.choices?.length ? ` [${i.choices.join(" | ")}]` : "";
      const source = i.source ? ` (${i.source})` : "";
      return `- ${i.id}: ${i.text}${options}${source}`;
    });
    console.log(
      `Open items on the user's Objective board:\n${lines.join("\n")}\n` +
        "If this message answers or resolves one, call objective_complete with " +
        "its id and the user's answer right away. Never ask the user to click " +
        "an item they already answered in chat."
    );
  }
} catch {
  // No board, no note. A hook must never block a prompt.
}
