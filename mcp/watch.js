// Waits on the state folder. Every part of Objective writes its files there,
// so a change wakes the waiter at once. The one-second poll is only a safety
// net for missed file events.

import fs from "node:fs";

// Calls `check` after every change, until it returns anything but undefined.
// Returns undefined when `signal` aborts. A `deadline` (ms since the epoch)
// makes the last check land on time.
export async function until(dir, check, { signal, deadline = Infinity } = {}) {
  let wake = null;
  let watcher = null;
  try {
    fs.mkdirSync(dir, { recursive: true });
    watcher = fs.watch(dir, () => wake?.());
  } catch {
    // Fall back to polling only.
  }
  const onAbort = () => wake?.();
  signal?.addEventListener("abort", onAbort);
  try {
    for (;;) {
      if (signal?.aborted) return undefined;
      const value = check();
      if (value !== undefined) return value;
      await new Promise((resolve) => {
        const timer = setTimeout(finish, Math.max(10, Math.min(1000, deadline - Date.now())));
        wake = finish;
        function finish() {
          clearTimeout(timer);
          wake = null;
          resolve();
        }
      });
    }
  } finally {
    watcher?.close();
    signal?.removeEventListener("abort", onAbort);
  }
}
