// Records which agent asked, so the board can jump you straight to it.
//
// Every MCP server is one Claude Code session, and it inherits that session's
// environment. That gives us the session id, the project, and the terminal
// device of the agent. While the agent is blocked, we also rename its terminal
// window to a marker only this item uses, so the overlay can raise exactly that
// window, even when it sits in a background tab.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const MARK = "◆";

// The MCP server is a child of the agent. Walk up until a process owns a tty.
function ownerTty(startPid) {
  let pid = startPid;
  for (let hop = 0; hop < 5 && pid > 1; hop++) {
    try {
      const [tty, ppid] = execFileSync("ps", ["-o", "tty=,ppid=", "-p", String(pid)], {
        encoding: "utf8",
      })
        .trim()
        .split(/\s+/);
      if (tty && tty !== "??" && tty !== "-") return tty;
      pid = Number(ppid);
    } catch {
      return null;
    }
  }
  return null;
}

export function captureOrigin() {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const sessionId = process.env.CLAUDE_CODE_SESSION_ID || null;
  const project = path.basename(projectDir);
  // Short enough to read in a tab bar, unique enough to tell two agents in the
  // same repo apart.
  const code = (sessionId ?? String(process.pid)).replace(/-/g, "").slice(0, 4);

  return {
    sessionId,
    project,
    projectDir,
    pid: process.ppid,
    tty: ownerTty(process.ppid),
    terminal: process.env.TERM_PROGRAM || null,
    marker: `${MARK} ${project} · ${code}`,
    code,
  };
}

// Writing a title escape sequence to the agent's terminal is invisible in the
// text, and it makes the waiting agent obvious in the tab bar.
function setTerminalTitle(origin, title) {
  if (!origin?.tty) return false;
  try {
    fs.writeFileSync(`/dev/${origin.tty}`, `\u001b]2;${title}\u0007`);
    return true;
  } catch {
    return false;
  }
}

export const markWaiting = (origin) => setTerminalTitle(origin, origin?.marker);

// Claude Code sets its own title again on its next turn; this is only so the
// marker does not outlive the question.
export const clearWaiting = (origin) =>
  setTerminalTitle(origin, origin?.project ?? os.hostname());
