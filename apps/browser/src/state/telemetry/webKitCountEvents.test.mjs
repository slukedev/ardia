import assert from "node:assert/strict";
import { after, test } from "node:test";
import { nativeEvents } from "../../test-native/events.ts";

const channel = nativeEvents();
globalThis.acTestNativeModules = {
  ...globalThis.acTestNativeModules,
  ArdiaWebKit: { call: () => Promise.resolve("null"), addListener: channel.addListener },
};
globalThis.fetch = async () => ({ status: 503 });

const client = await import("./client.ts");
const { startWebKitCounts, takeEngineSwitchCounts } = await import("./engineSwitchCounts.ts");
after(() => client.setSharing(false, "settings"));

const counted = (name) => channel.emit("webKit", { name: "webKit.counted", data: { name, epoch: client.consentEpoch() } });

test("WebKit page counts from native reach the hourly counts once the app starts listening, never twice", () => {
  client.loadChoice();
  client.setSharing(true, "settings");
  takeEngineSwitchCounts();
  counted("contextMenu");
  assert.equal(takeEngineSwitchCounts().webkit_context_menus, 0, "importing the counts module listens to nothing");
  startWebKitCounts();
  startWebKitCounts();
  counted("contextMenu");
  counted("certificateInterstitial");
  const counts = takeEngineSwitchCounts();
  assert.equal(counts.webkit_context_menus, 1);
  assert.equal(counts.webkit_certificate_interstitials, 1);
});
