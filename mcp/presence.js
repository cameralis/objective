// Whether the user sits at the Mac, as the Objective app reads it.
//
// The app owns every signal and writes one reading to presence.json. The MCP
// servers only read that file, so they all agree. A reading from an app that no
// longer runs says nothing, so it counts as unknown.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { until } from "./watch.js";

const STATE_DIR =
  process.env.OBJECTIVE_STATE_DIR ||
  path.join(os.homedir(), "Library", "Application Support", "Objective");
const PRESENCE_FILE = path.join(STATE_DIR, "presence.json");

// How long the banner of a new item may go unanswered before an unsure user
// counts as away.
export const CHECK_SECONDS = Number(process.env.OBJECTIVE_PRESENCE_CHECK_SECONDS ?? 60);

export function readPresence() {
  let presence;
  try {
    presence = JSON.parse(fs.readFileSync(PRESENCE_FILE, "utf8"));
  } catch {
    return null;
  }
  if (!["present", "unsure", "away"].includes(presence?.state)) return null;
  return isAlive(presence.pid) ? presence : null;
}

function isAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === "EPERM";
  }
}

// Present, away, or unknown. An unsure user gets CHECK_SECONDS: the banner has
// just played, and real input or an unlock answers it. Silence means away.
// Returns "closed" as soon as `isOpen` says nobody needs the answer any more.
export function settle({ isOpen = () => true, signal } = {}) {
  const deadline = Date.now() + CHECK_SECONDS * 1000;
  return until(
    STATE_DIR,
    () => {
      if (!isOpen()) return "closed";
      const presence = readPresence();
      if (!presence) return "unknown";
      if (presence.state !== "unsure") return presence.state;
      if (Date.now() >= deadline) return "away";
    },
    { signal, deadline }
  );
}
