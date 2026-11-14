import assert from "node:assert/strict";
import { test } from "node:test";

const { useBrowser } = await import("../browser/store.ts");
const model = await import("../browser/model.ts");
const { webviews } = await import("../../platform/webviews.ts");
const { dropSwap, firstPaintScript, holdPageForSwap, swapping, useRetiringPages, watchFirstPaint } = await import("./engineSwap.ts");
const { takeEngineSwitchCounts } = await import("../telemetry/engineSwitchCounts.ts");
const { forWebKit } = await import("./webKitExtensions.ts");

const S = () => useBrowser.getState();
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

function pageTab() {
  S().hydrate({});
  const w = S().createWindow({ url: "https://video.example/watch/1" });
  return model.activeTabId(S(), w);
}

test("the old page stays up until the new one paints at the old scroll position, then goes", async () => {
  const tabId = pageTab();
  takeEngineSwitchCounts();
  webviews.set(tabId, { evaluate: async () => ({ x: 0, y: 840 }) });
  await holdPageForSwap(tabId, "chromium", "webkit", "https://video.example/watch/1", true);
  assert.deepEqual(useRetiringPages.getState()[tabId], { engine: "chromium" });
  assert.equal(swapping(tabId), true);
  const asked = [];
  let painted = false;
  webviews.set(tabId, { evaluate: async (code) => (asked.push(code), painted) });
  watchFirstPaint(tabId, "chromium", true);
  await tick(10);
  assert.equal(asked.length, 0, "a page in the engine it left never ends the swap");
  watchFirstPaint(tabId, "webkit", true);
  await tick(10);
  assert.equal(useRetiringPages.getState()[tabId]?.engine, "chromium");
  assert.match(asked[0], /"y":840/);
  painted = true;
  await tick(120);
  assert.equal(useRetiringPages.getState()[tabId], undefined);
  assert.equal(swapping(tabId), false);
  const counts = takeEngineSwitchCounts();
  assert.equal(counts.engine_switches, 1);
  assert.equal(counts.engine_switches_to_webkit, 1);
  assert.equal(counts.engine_switch_scroll_carried, 1);
  assert.equal(counts.engine_switch_timeouts, 0);
  webviews.clear();
});

test("a tab out of sight swaps at once and leaves its time out of the switch timing", async () => {
  const tabId = pageTab();
  takeEngineSwitchCounts();
  webviews.set(tabId, { evaluate: async () => ({ x: 0, y: 0 }) });
  await holdPageForSwap(tabId, "webkit", "chromium", "https://video.example/watch/1", true);
  watchFirstPaint(tabId, "chromium", false);
  assert.equal(swapping(tabId), false);
  const counts = takeEngineSwitchCounts();
  assert.equal(counts.engine_switches_hidden, 1);
  assert.equal(counts.engine_switch_ms_total, 0);
  webviews.clear();
});

test("dropping a swap clears the held page without counting a switch", async () => {
  const tabId = pageTab();
  takeEngineSwitchCounts();
  await holdPageForSwap(tabId, "chromium", "webkit", "https://video.example/", false);
  dropSwap(tabId);
  assert.equal(useRetiringPages.getState()[tabId], undefined);
  assert.equal(takeEngineSwitchCounts().engine_switches, 0);
});

test("the paint check waits for real content and only scrolls when the page is tall enough", () => {
  const script = firstPaintScript({ x: 0, y: 1200 });
  assert.match(script, /first-contentful-paint/);
  assert.match(script, /about:blank/);
  assert.match(script, /room \+ 1 < target\.y/);
  assert.doesNotMatch(firstPaintScript(null), /"y"/);
});

test("WebKit gets the extensions that are on, with Chromium's site access", () => {
  const ext = (id, more) => ({ id, name: id, version: "1.0", enabled: true, state: "ENABLED", path: null, sites: [], siteAccess: "ON_ALL_SITES", incognito: false, ...more });
  const list = forWebKit([
    ext("bbbb", { siteAccess: "ON_SPECIFIC_SITES", sites: ["https://b.example/*", "https://a.example/*"] }),
    ext("aaaa", { path: "/Users/me/dev/ext" }),
    ext("cccc", { enabled: false, state: "DISABLED" }),
    ext("dddd", { blockedByPolicy: true }),
    ext("eeee", { siteAccess: "ON_CLICK", sites: ["https://c.example/*"] }),
  ]);
  assert.deepEqual(list.map((x) => x.id), ["aaaa", "bbbb", "eeee"]);
  assert.equal(list[0].path, "/Users/me/dev/ext");
  assert.deepEqual(list[1].sites, ["https://a.example/*", "https://b.example/*"]);
  assert.equal(list[1].allSites, false);
  assert.deepEqual([list[2].allSites, list[2].sites], [false, []]);
});
