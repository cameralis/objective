# Objective

A small objective board for Claude. When Claude needs your decision, your input, or an
action only you can do, it adds an item. You answer, and the answer flows back to Claude.

Two front ends read the same board:

- a macOS Liquid Glass overlay, always on top, like a game HUD;
- a Telegram bot, for when you are away from the Mac.

## Parts

- `app/` — native SwiftUI app. A borderless, non-activating glass panel that floats above all windows and spaces. A `scope` icon in the menu bar shows or hides it.
- `mcp/` — MCP server (Node, stdio). Tools: `objective_add`, `objective_list`, `objective_complete`, `objective_remove`, `objective_clear`, `objective_wait`.
- `telegram/` — Telegram bridge (Node, no dependencies). Each objective becomes a chat message with buttons.
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
- Click an item to check it off. It lingers a few seconds, then fades out.
- Drag the panel anywhere; the position is remembered.
- Done items are pruned from the state file after one day.

## The Telegram bot

Each open objective is one chat message. There is no always-visible board: the chat is the board.

```sh
# 1. Talk to @BotFather in Telegram, send /newbot, copy the token.
make telegram-token TOKEN=<bot token>

# 2. Start the bridge, then send /start to your bot to link the chat.
make telegram

# 3. Optional: keep it running in the background.
make telegram-service
```

- **Choices** become inline buttons. Tap one; the answer goes back to Claude at once.
- **Reply items** ask for text. Reply to the message and your text is the answer. Plain text with no reply goes to the newest item that asked for text.
- **Plain items** get a `✓ Done` button.
- **Urgent** items show 🔴 and an `#urgent` tag. The `source` becomes a hashtag, so you can filter by project.
- When an item is answered anywhere (bot, overlay, or Claude), the chat message is edited: struck through, with the answer below it.
- Commands: `/list`, `/help`, `/id`.

`make telegram-test` runs the bridge end to end against a fake Telegram server, so you can
check the message flow without a bot.

The bot token is stored in `~/Library/Application Support/Objective/telegram.json`, outside the
repository. `OBJECTIVE_TELEGRAM_TOKEN` and `OBJECTIVE_TELEGRAM_CHAT_ID` override it.
The bridge only accepts updates from the linked chat.

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

Claude calls `objective_wait` to block until you answer. It returns your answer.

## Launch at login

Add `~/Applications/Objective.app` in System Settings → General → Login Items.
The Telegram bridge starts itself after `make telegram-service`.

## Requirements

macOS 15 or later (real `.glassEffect` needs macOS 26), Swift 6 toolchain, Node 18 or later.

## License

MIT.
