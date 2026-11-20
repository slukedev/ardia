import assert from "node:assert/strict";
import { test } from "node:test";

const { useBrowser } = await import("../browser/store.ts");
const model = await import("../browser/model.ts");
const { webviews } = await import("../../platform/webviews.ts");
const { dropSwap, firstPaintScript, heldBySwap, holdPageForSwap, swapping, SWAP_DEADLINE_MS, useRetiringPages, watchFirstPaint } = await import("./engineSwap.ts");
const { liveOf } = await import("../tabs/tabLive.ts");
const { pageProgressOf } = await import("../tabs/pageProgress.ts");
const { takeEngineSwitchCounts } = await import("../telemetry/engineSwitchCounts.ts");
const { setConsentPeriod } = await import("../telemetry/consentPeriod.ts");
setConsentPeriod(true, "engine-swap-test");

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

test("with Keep the page on screen off, a switch holds nothing and counts no swap", async () => {
  const tabId = pageTab();
  takeEngineSwitchCounts();
  S().updateSettings({ engineSwitchKeepsPage: false });
  webviews.set(tabId, { evaluate: async () => ({ x: 0, y: 840 }) });
  await holdPageForSwap(tabId, "chromium", "webkit", "https://video.example/watch/1", true);
  assert.equal(useRetiringPages.getState()[tabId], undefined);
  assert.equal(swapping(tabId), false);
  assert.equal(takeEngineSwitchCounts().engine_switches ?? 0, 0);
  S().updateSettings({ engineSwitchKeepsPage: true });
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

function runPaintCheck(script, page) {
  const posted = [];
  const frames = [];
  const scrolls = [];
  const env = {
    post: (_kind, value) => posted.push(value),
    location: { protocol: page.protocol ?? "https:", href: page.href ?? "https://video.example/" },
    performance: { getEntriesByName: () => (page.painted ? [{}] : []) },
    document: { readyState: page.readyState ?? "interactive", visibilityState: page.visibility ?? "visible", scrollingElement: { scrollHeight: page.height ?? 4000 } },
    innerHeight: 800,
    scrollX: 0,
    scrollY: 0,
    scrollTo: (x, y) => scrolls.push([x, y]),
    requestAnimationFrame: (run) => frames.push(run),
  };
  new Function(...Object.keys(env), script)(...Object.values(env));
  let ran = 0;
  while (frames.length) (frames.shift()(), ran++);
  return { posted, frames: ran, scrolls };
}

test("the paint check waits for real content, scrolls only when the page is tall enough, and waits two frames only when the swap is on screen", () => {
  assert.deepEqual(runPaintCheck(firstPaintScript(null, true), { painted: false }).posted, ["false"]);
  assert.deepEqual(runPaintCheck(firstPaintScript(null, true), { painted: true, href: "about:blank", protocol: "about:" }).posted, ["false"]);
  const short = runPaintCheck(firstPaintScript({ x: 0, y: 1200 }, true), { painted: true, height: 900 });
  assert.deepEqual([short.posted, short.scrolls], [["false"], []]);
  const tall = runPaintCheck(firstPaintScript({ x: 0, y: 1200 }, true), { painted: true, height: 4000 });
  assert.deepEqual([tall.posted, tall.scrolls], [["true"], [[0, 1200]]]);
  const hidden = runPaintCheck(firstPaintScript(null, false), { painted: true, visibility: "hidden" });
  assert.deepEqual(hidden.posted, ["true"], "a tab out of sight swaps without waiting on frames");
  const shownButHidden = runPaintCheck(firstPaintScript(null, true), { painted: true, visibility: "hidden" });
  assert.deepEqual(shownButHidden.posted, ["true"], "a shown swap waits two frames, even if the page calls itself hidden");
  assert.equal(shownButHidden.frames, 2);
});

test("a swap ends 3 seconds after the hold even when the new page never reports ready, and counts as timed out", async (t) => {
  const tabId = pageTab();
  takeEngineSwitchCounts();
  t.mock.timers.enable({ apis: ["setTimeout"] });
  webviews.set(tabId, { evaluate: async () => null });
  await holdPageForSwap(tabId, "chromium", "webkit", "https://video.example/watch/1", false);
  t.mock.timers.tick(SWAP_DEADLINE_MS - 1);
  assert.equal(swapping(tabId), true);
  t.mock.timers.tick(1);
  assert.equal(swapping(tabId), false);
  assert.equal(useRetiringPages.getState()[tabId], undefined);
  assert.equal(takeEngineSwitchCounts().engine_switch_timeouts, 1);
  webviews.clear();
});

test("loading and progress muted during a swap come back when it ends", async () => {
  const tabId = pageTab();
  await holdPageForSwap(tabId, "chromium", "webkit", "https://video.example/", false);
  assert.equal(heldBySwap(tabId, { isLoading: true }), true);
  assert.equal(heldBySwap(tabId, { progress: 0.4 }), true);
  dropSwap(tabId);
  assert.equal(liveOf(tabId).isLoading, true);
  assert.equal(pageProgressOf(tabId), 0.4);
  assert.equal(heldBySwap(tabId, { isLoading: false }), false);
});

test("dropping someone else's swap leaves the current one, and a closed tab's swap ends without being counted", async () => {
  const tabId = pageTab();
  takeEngineSwitchCounts();
  const first = await holdPageForSwap(tabId, "chromium", "webkit", "https://video.example/", false);
  const second = await holdPageForSwap(tabId, "chromium", "webkit", "https://video.example/", false);
  dropSwap(tabId, first);
  assert.equal(swapping(tabId), true);
  dropSwap(tabId, null);
  assert.equal(swapping(tabId), true);
  webviews.set(tabId, { evaluate: async () => true });
  S().closeTab(tabId);
  watchFirstPaint(tabId, "webkit", true);
  await tick(20);
  assert.equal(swapping(tabId), false);
  assert.equal(takeEngineSwitchCounts().engine_switches ?? 0, 0);
  dropSwap(tabId, second);
  webviews.clear();
});
