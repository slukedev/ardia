import assert from "node:assert/strict";
import { after, test } from "node:test";

globalThis.__DEV__ = false;
await import("../../test-native/index.ts");
globalThis.fetch = async () => ({ status: 503 });

const client = await import("./client.ts");
const { noteEngineModeChange, noteEngineSwap, takeEngineSwitchCounts } = await import("./engineSwitchCounts.ts");
after(() => client.setSharing(false, "settings"));

const swap = { ms: 120, timedOut: false, hidden: false, scroll: true, zoom: false };

test("engine counts land only under the consent period they started in, and a new period starts from zero", () => {
  client.loadChoice();
  client.setSharing(true, "settings");
  const before = client.consentToken();
  takeEngineSwitchCounts();
  noteEngineSwap("webkit", swap, before);
  noteEngineModeChange({ cancelled: false, moved: 2 }, before);

  client.setSharing(false, "settings");
  client.setSharing(true, "settings");
  const now = client.consentToken();
  assert.notEqual(now, before);
  noteEngineSwap("webkit", swap, before);
  noteEngineSwap("webkit", swap, null);
  noteEngineSwap("webkit", swap, now);
  const counts = takeEngineSwitchCounts();
  assert.equal(counts.engine_switches, 1);
  assert.equal(counts.engine_switch_scroll_carried, 1);
  assert.equal(counts.engine_mode_changes, 0);
  assert.equal(counts.engine_mode_tabs_moved, 0);
});
