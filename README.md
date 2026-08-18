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

- `app/` — native SwiftUI app. A borderless, non-activating glass panel that floats above all windows and spaces. A `scope` icon in the menu bar shows or hides it.
- `mcp/` — MCP server (Node, stdio). Tools: `objective_add`, `objective_list`, `objective_complete`, `objective_remove`, `objective_clear`, `objective_wait`.
- `relay/` — the Telegram side: one shared bot on a Cloudflare Worker, paired with a code. See `relay/README.md`.
- Shared state: `~/Library/Application Support/Objective/state.json`. Every part watches the file, so updates are immediate and bidirectional. You can run the overlay, the bot, or both.

## Build and install

```sh
make deps      # pnpm install for the MCP server
make run       # build the app, install to ~/Applications, launch
```

Register the MCP server with Claude Code:

```sh
claude mcp add -s user objective -- node "$(pwd)/mcp/index.js"
```

## The overlay

- Claude calls `objective_add`. The item slides in with a glow, a sound plays, and a notification shows.
- **Click the row to jump to the agent that asked.** The right terminal window comes forward,
  and the right tab is selected, even with several agents in the same repo.
- **Click the circle to check the item off.** Answer buttons answer it directly.
- **`Other…`** opens a text field, for the answer that is not on a button.
- **Blocked first.** An agent stuck inside its tool call sorts to the top and shows how long
  it has waited. An item whose session died greys out and says so.
- The list scrolls once it is long, so a busy queue never covers the screen.
- Drag the panel anywhere; the position is remembered.
- Done items are pruned from the state file after one day.

### How the jump works

Each MCP server is one Claude Code session, so it knows the session id, the project, and
the terminal device of its agent. While the agent waits, the server renames that terminal
window to a marker only this item uses, which also makes the waiting agent visible in the
tab bar. The overlay activates the terminal and raises exactly that window or tab through
accessibility. macOS asks once for permission.

## The shared bot (recommended)

One bot serves everybody, so a user never creates a bot. Deploy the Worker once, then:

```sh
# In Telegram: open the bot, tap Start, copy the eight character code.
make relay-pair CODE=XXXXXXXX URL=https://objective-relay.<you>.workers.dev
```

After that the MCP server posts every item to the relay and waits on the overlay
and on Telegram at the same time. The first answer wins. Deployment steps are in
`relay/README.md`.

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

`objective_add` blocks by default and returns your answer as the result of the tool call.
The agent is held inside that call, so your click reaches it in milliseconds, with no polling
and no "tell me when you are done". The state directory is watched, so the wake-up is immediate.

There is no deadline by default. You may answer hours later. Claude Code moves a long call to
the background after about two minutes and delivers the answer as a notification, so the agent
pays nothing for waiting.

Pass `wait: false` for an item that does not block the agent, then `objective_wait` later if
the answer turns out to matter.

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
