# Objective relay

One shared Telegram bot for every user, on Cloudflare Workers. Users never touch
@BotFather. They send `/start`, get a code, and paste it once.

## Why a server is needed at all

A shared bot has one token. The token cannot ship inside the Mac app, because
anybody could extract it, read every user's messages, and write as the bot. So
the token lives in this Worker, and Telegram talks to the Worker.

## How it fits together

```
Mac (MCP server) --POST /v1/items--> Worker --sendMessage--> Telegram --> your phone
your phone --tap--> Telegram --webhook--> Worker --> Durable Object stores the answer
Mac (long poll on /v1/item) <--answer-- Worker
```

Each Telegram chat gets one Durable Object. It is the only writer, so a long
poll returns the instant you tap a button. If your Mac sleeps, the answer waits
in the object and arrives when the Mac wakes.

Account keys are signed, not stored: `ob1.<chatId>.<epoch>.<hmac>`. The Worker
reads the chat id from the key to find the object, and the object checks the
signature. `/unlink` raises the epoch, which kills every key that chat handed
out.

## Deploy

```sh
cd relay && pnpm install
pnpm dlx wrangler login

# 1. Create the shared bot once with @BotFather, then store the secrets.
make relay-secrets          # BOT_TOKEN, KEY_SECRET, WEBHOOK_SECRET

# 2. Ship it.
make relay-deploy

# 3. Point Telegram at it.
make relay-webhook TOKEN=<bot token> URL=https://objective-relay.<you>.workers.dev SECRET=<webhook secret>
```

`KEY_SECRET` and `WEBHOOK_SECRET` are any long random strings. Generate them
with `openssl rand -hex 32`.

## Pair a Mac

1. Open the bot in Telegram and tap **Start**.
2. The bot replies with an eight character code.
3. On the Mac: `make relay-pair CODE=XXXXXXXX URL=https://objective-relay.<you>.workers.dev`

The key is written to `~/Library/Application Support/Objective/relay.json`. From
then on the MCP server posts every item to the relay and waits on the overlay and
Telegram at the same time. The first answer wins, and the other side is updated.

`/unlink` in the chat revokes every paired Mac.

## Tests

`make relay-test` runs the Worker and its Durable Object in plain Node, with
stubbed storage and a stubbed Telegram API, then runs the MCP server against a
real relay over HTTP. No deployment and no wrangler needed.

## Cost

The free plan covers this. Durable Objects with SQLite storage are included, and
each objective is a handful of small requests.
