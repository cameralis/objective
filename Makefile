APP_NAME = Objective
BUILD_DIR = build
BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR = $(HOME)/Applications

.PHONY: build bundle install run deps clean icon test mcp-test relay-test relay-deploy relay-secrets relay-webhook relay-pair

build:
	swift build -c release --package-path app

icon:
	mkdir -p $(BUILD_DIR)/icon.iconset
	swift scripts/makeicon.swift $(BUILD_DIR)/icon_1024.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s $(BUILD_DIR)/icon_1024.png --out $(BUILD_DIR)/icon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		d=$$((s * 2)); \
		sips -z $$d $$d $(BUILD_DIR)/icon_1024.png --out $(BUILD_DIR)/icon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(BUILD_DIR)/icon.iconset -o $(BUILD_DIR)/AppIcon.icns

bundle: build icon
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp app/.build/release/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp app/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(BUILD_DIR)/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUNDLE)

install: bundle
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(BUNDLE) $(INSTALL_DIR)/$(APP_NAME).app

run: install
	open -g $(INSTALL_DIR)/$(APP_NAME).app

deps:
	cd mcp && pnpm install

test: mcp-test relay-test

mcp-test:
	node mcp/test-mcp.mjs

relay-test:
	node relay/test-relay.mjs
	node mcp/test-relay-e2e.mjs

relay-deploy:
	cd relay && pnpm dlx wrangler deploy

# One-time secrets for the shared bot. Run each and paste the value.
relay-secrets:
	cd relay && pnpm dlx wrangler secret put BOT_TOKEN
	cd relay && pnpm dlx wrangler secret put KEY_SECRET
	cd relay && pnpm dlx wrangler secret put WEBHOOK_SECRET

# Point Telegram at the deployed relay. TOKEN, URL and SECRET are required.
relay-webhook:
	@test -n "$(TOKEN)" && test -n "$(URL)" && test -n "$(SECRET)" || \
		{ echo "usage: make relay-webhook TOKEN=<bot token> URL=<relay url> SECRET=<webhook secret>"; exit 1; }
	curl -sS "https://api.telegram.org/bot$(TOKEN)/setWebhook" \
		-d "url=$(URL)/telegram/webhook" \
		-d "secret_token=$(SECRET)" \
		-d "allowed_updates=[\"message\",\"callback_query\"]"
	@echo

# Link this Mac to the shared bot. Send /start to the bot to get a code.
relay-pair:
	@test -n "$(CODE)" || { echo "usage: make relay-pair CODE=XXXXXXXX [URL=<relay url>]"; exit 1; }
	node mcp/index.js --pair $(CODE) $(if $(URL),--url $(URL),)

clean:
	rm -rf $(BUILD_DIR) app/.build
