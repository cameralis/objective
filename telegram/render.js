// How an objective looks in Telegram.
// Shared by the local bridge (Node) and the shared-bot relay (Cloudflare
// Workers), so both send exactly the same message. No imports on purpose: this
// file must run in both runtimes.

export const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

export const hashtag = (s) => `#${String(s).replace(/[^\p{L}\p{N}_]+/gu, "_")}`;

export function renderText(item, { removed = false } = {}) {
  const lines = [];
  if (removed) {
    lines.push(`🚫 <s>${esc(item.text)}</s>`);
  } else if (item.status === "done") {
    lines.push(`✅ <s>${esc(item.text)}</s>`);
  } else {
    lines.push(`${item.urgent ? "🔴" : "🎯"} <b>${esc(item.text)}</b>`);
  }

  if (item.detail) lines.push(esc(item.detail));

  if (item.status === "open" && item.allowReply) {
    lines.push("<i>Reply to this message with your answer.</i>");
  }

  if (item.answer) lines.push(`\n💬 <b>${esc(item.answer)}</b>`);
  else if (removed) lines.push("\n<i>Withdrawn.</i>");
  else if (item.status === "done") lines.push("\n<i>Done.</i>");

  const meta = [];
  if (item.source) meta.push(hashtag(item.source));
  if (item.urgent && item.status === "open") meta.push("#urgent");
  if (meta.length) lines.push(`\n<i>${esc(meta.join(" "))}</i>`);

  return lines.join("\n");
}

// Inline keyboards survive an edit; force_reply does not, so it is only used
// on the first send.
export function inlineKeyboard(item) {
  if (item.status !== "open") return null;
  if (item.choices?.length) {
    const wide = item.choices.some((c) => c.length > 14);
    const buttons = item.choices.map((choice, i) => ({
      text: choice,
      callback_data: `c|${item.id}|${i}`,
    }));
    const rows = [];
    for (let i = 0; i < buttons.length; i += wide ? 1 : 2) {
      rows.push(buttons.slice(i, i + (wide ? 1 : 2)));
    }
    return { inline_keyboard: rows };
  }
  if (item.allowReply) return null;
  return {
    inline_keyboard: [[{ text: "✓ Done", callback_data: `d|${item.id}` }]],
  };
}

export function sendMarkup(item) {
  const keyboard = inlineKeyboard(item);
  if (keyboard) return keyboard;
  if (item.status === "open" && item.allowReply) {
    return {
      force_reply: true,
      input_field_placeholder: "Your answer",
      selective: false,
    };
  }
  return undefined;
}
