import assert from "node:assert/strict";
import { after, test } from "node:test";

globalThis.__DEV__ = false;
await import("../../test-native/index.ts");
globalThis.fetch = async () => ({ status: 503 });

const client = await import("./client.ts");
const { noteEngineModeChange, noteWebKitCount, takeEngineSwitchCounts } = await import("./engineSwitchCounts.ts");
after(() => client.setSharing(false, "settings"));

test("engine and WebKit counts land only under the consent period they started in, and a new period starts from zero", () => {
  client.loadChoice();
  client.setSharing(true, "settings");
  const before = client.consentToken();
  takeEngineSwitchCounts();
  noteWebKitCount("contextMenu", before);
  noteWebKitCount("blockerStrictBlocked", before);
  noteEngineModeChange({ cancelled: false, moved: 2 }, before);

  client.setSharing(false, "settings");
  client.setSharing(true, "settings");
  const now = client.consentToken();
  assert.notEqual(now, before);
  noteWebKitCount("contextMenu", before);
  noteWebKitCount("contextMenu", null);
  noteWebKitCount("contextMenu", now);
  const counts = takeEngineSwitchCounts();
  assert.equal(counts.webkit_context_menus, 1);
  assert.equal(counts.webkit_blocker_strict_blocks, 0);
  assert.equal(counts.engine_mode_changes, 0);
  assert.equal(counts.engine_mode_tabs_moved, 0);
});
