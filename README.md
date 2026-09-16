# Objective

A queue for blocked agents. When many agents work at once, this is the one place that
shows which of them is stalled and waiting for you. Click an item and the terminal window
of the agent that asked comes to the front.

It is deliberately not a chat client. Only two kinds of ask belong on the board:

- a **permission** the agent lacks: publish, send, delete, spend;
- a **fact** only you hold: which name, is it paid.

Both fit in one line, so buttons answer them well. A judgement call about design or
tradeoffs stays in the session, where the agent can explain and you can read the code.

Two front ends read the same board:

- a macOS Liquid Glass overlay, always on top, like a game HUD;
- a Telegram bot, for when you are away from the Mac.

One shared bot serves everybody, so no user ever talks to @BotFather. Nothing extra runs
on your Mac for it.

## Parts

- `app/` — native SwiftUI app. A borderless, non-activating glass panel that floats above all windows and spaces. A `scope` icon in the menu bar controls it.
- `mcp/` — MCP server (Node, stdio). Tools: `objective_add`, `objective_presence`, `objective_list`, `objective_complete`, `objective_remove`, `objective_clear`, `objective_wait`.
- `relay/` — the Telegram side: one shared bot on a Cloudflare Worker, paired with a code. See `relay/README.md`.
- Shared state: `~/Library/Application Support/Objective/state.json`, and the app's presence reading next to it in `presence.json`. Every part watches the folder, so updates are immediate and bidirectional. You can run the overlay, the bot, or both.

## Build and install

```sh
make deps      # pnpm install for the MCP server
make run       # build the app, install to ~/Applications, launch
```

Register the MCP server with Claude Code:

```sh
claude mcp add -s user objective -- node "$(pwd)/mcp/index.js"
```

Codex uses the same server. The **Objective Enabled** setting adds it to `~/.codex/config.toml`
with a seven-day tool timeout, so a waiting call is never stopped, and adds the instructions to
`~/.codex/AGENTS.md`.

## The overlay

- Claude calls `objective_add`. The item slides in with a glow, a sound plays, and a notification shows.
- **Click the row to jump to the agent that asked.** The right terminal window comes forward,
  and the right tab is selected, even with several agents in the same repo.
- **Click the circle to check the item off.** Answer buttons answer it directly.
- **`Other…`** opens a text field, for the answer that is not on a button.
- **Blocked first.** An agent stuck inside its tool call sorts to the top and shows how long
  it has waited. An item whose session died greys out and says so.
- The list scrolls once it is long, so a busy queue never covers the screen.
- **All clear contracts the panel** to a small capsule badge on the screen edge it hangs from.
  The next item expands it again. Click the badge to open the card, and the `All clear` row to
  contract it.
- Drag the panel anywhere; the position is remembered, and the badge keeps the same corner.
- The menu bar has an **Objective Enabled** setting. Turning it off removes the global
  Objective instructions and prompt hook, disables the user-scoped MCP server in Claude Code
  and Codex, and hides the overlay. Turning it on restores the saved setup. Start a new
  session after changing it because an open session keeps the tools and instructions it
  started with.
- Done items are pruned from the state file after one day.

### How the jump works

Each MCP server is one Claude Code session, so it knows the session id, the project, and
the terminal device of its agent. While the agent waits, the server renames that terminal
window to a marker only this item uses, which also makes the waiting agent visible in the
tab bar. Claude Code owns that title and repaints it, so the overlay writes the marker again,
to the terminal device of the agent, at the moment you click. It then raises exactly that
window or tab through the accessibility API, which macOS asks about once, in Privacy &
Security > Accessibility. An item that carries no marker falls back to the project name, and
to every terminal that runs now. If nothing matches, the app tells you in a notification.

An ad-hoc signature is different after each build, so macOS drops both permissions on every
`make run`. Build with a stable identity to keep them: put the identity in `.signid` (the file
is ignored by git), or pass it on the command line.

```sh
security find-identity -v -p codesigning
echo "Apple Development: Your Name (XXXXXXXXXX)" > .signid
make run
```

If the switch in the Accessibility list is on but the jump still says the app is not trusted,
the entry belongs to the old signature. Clear it once and allow it again:

```sh
tccutil reset Accessibility io.github.cameralis.objective
```

Each jump writes one line to `~/Library/Application Support/Objective/focus.log`, which says
what was searched and what was raised.

## Presence

Telegram is the push notification for when you are away, so Objective must know whether you
sit at the Mac. The app reads it from what you do, and writes one reading to `presence.json`.

| Signal | What it reads |
| --- | --- |
| Real input | Keys, clicks, mouse moves, and scrolls. An event counts only when the system or a mouse driver (Logi Options+) sent it, so fake input from computer use never counts as you. The app keeps the time of the last event, never the keys. |
| Screen lock | A lock cancels the input before it. An unlock counts as you. |
| Lid | Closed with no external display means away. |
| iPhone | Out of Bluetooth range for three minutes means away. In range proves nothing. |
| Call | An app that records from the microphone keeps you present. Objective never opens the microphone. |

| State | When |
| --- | --- |
| `present` | Real input in the last 90 seconds, or a call, while the screen is unlocked |
| `away` | Lid closed with no display, iPhone gone for three minutes, or no input for 15 minutes |
| `unsure` | Anything else, such as a few quiet minutes or a fresh lock |

How a new item reaches you:

- **present**: the overlay, a sound, and a banner. No Telegram.
- **unsure**: the same banner, then a 60 second check. Real input or an unlock in that time
  means you saw it. Silence sends the item to Telegram.
- **away**: Telegram at once.
- If you leave while an item is open, it goes to Telegram then.
- If the app does not run, every item goes to Telegram, because nobody can tell.

The menu bar shows the reading and lets you correct it: **Here for 1 Hour** (a lock ends it),
**Away Until I Return** (your next input after one minute ends it), and **Detect Automatically**.

Real input needs **Input Monitoring**, which macOS asks for once, in Privacy & Security >
Input Monitoring. Without it the app falls back to the system idle timer, where fake input
counts as you, and the menu shows **Allow Input Monitoring…**.

### Steps at the Mac

Touch ID, a sudo prompt, or a system dialog times out when nobody sees it. So an agent calls
`objective_add` with `at_mac: true` before it starts such a step:

- You are at the Mac: the call returns `present` at once and the agent starts the step. A banner
  says what is coming, and the item stays on the board while the step runs, so you can read it.
  It asks nothing and closes itself after two minutes, or the moment you check it off.
- You are away: the item goes on the board and to Telegram, and the call waits. When you come
  back, a sound and a banner say so, the Telegram message closes, and the call returns `present`.
- **Skip**, on the board or in Telegram, returns `skipped`, and the agent leaves the step undone.
- Without the app, the item asks you with **Ready** and **Skip**.

`objective_presence` returns the current reading, so an agent can plan its work around it.

## The shared bot (recommended)

One bot serves everybody, so a user never creates a bot. Deploy the Worker once, then:

```sh
# In Telegram: open the bot, tap Start, copy the eight character code.
make relay-pair CODE=XXXXXXXX URL=https://objective-relay.<you>.workers.dev
```

After that an item goes to the relay when you are away from the Mac (see Presence), and the
MCP server waits on the overlay and on Telegram at the same time. The first answer wins.
Deployment steps are in `relay/README.md`.

### In the chat

- **Choices** become inline buttons. Tap one; the answer goes back to the agent at once.
- **Reply items** ask for text. Reply to the message and your text is the answer. Plain text with no reply goes to the newest item that asked for text.
- **Plain items** get a `✓ Done` button.
- **Urgent** items show 🔴 and an `#urgent` tag. The `source` becomes a hashtag, so you can filter by project.
- When an item is answered anywhere, the chat message is edited: struck through, with the answer below it.
- Commands: `/start` pairs a Mac, `/unlink` revokes every paired Mac, `/help`.

There is no jump from Telegram, because there is no window to raise on your phone. That is
the one thing the overlay does and the chat cannot.

## Item options

`objective_add` accepts:

| Option | Effect |
| --- | --- |
| `text` | Short objective text. |
| `detail` | One extra line of context. |
| `choices` | 2-4 answer buttons. |
| `allow_reply` | Free-text answer field. |
| `urgent` | Red styling, stronger sound, sorts to the top. |
| `source` | Project or repo label. |
| `wait` | Block until you answer (default `true`). |
| `at_mac` | Wait until you are at the Mac, for Touch ID, a password, or a dialog. Returns `present` or `skipped`. |

`objective_add` blocks by default and returns your answer as the result of the tool call.
The agent is held inside that call, so your click reaches it in milliseconds, with no polling
and no "tell me when you are done". The state directory is watched, so the wake-up is immediate.

There is no deadline by default. You may answer hours later. Claude Code moves a long call to
the background after about two minutes and delivers the answer as a notification, so the agent
pays nothing for waiting.

Pass `wait: false` for an item that does not block the agent, then `objective_wait` later if
the answer turns out to matter.

If the agent stops waiting, the question leaves the board. Stopping the tool call, or ending
the session, removes the item and closes its Telegram message, because nobody is left to read
the answer.

If you answer in chat instead of on the board, the agent closes the item for you. The
`scripts/open-objectives-hook.mjs` hook lists the open items on every message, so the agent
always knows what is still waiting. Register it as a `UserPromptSubmit` hook.

Run the tests with `make test`.

## Launch at login

Add `~/Applications/Objective.app` in System Settings → General → Login Items.

## Requirements

macOS 15 or later (real `.glassEffect` needs macOS 26), Swift 6 toolchain, Node 18 or later.

## License

MIT.
