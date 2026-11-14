import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";

globalThis.__DEV__ = false;
const stubs = {
  "../tabs/tabPages": "export const wantsPage = (t) => !!t && !!(t.page.nav || t.page.adopt);",
};
registerHooks({
  resolve(specifier, context, next) {
    if (!context.parentURL?.endsWith("/state/engines/actions.ts") || !(specifier in stubs)) return next(specifier, context);
    return { url: `data:text/javascript,${encodeURIComponent(stubs[specifier])}`, shortCircuit: true };
  },
});

const { useBrowser } = await import("../browser/store.ts");
const model = await import("../browser/model.ts");
const { webviews } = await import("../../platform/webviews.ts");
const { patchPage, pageOf } = await import("../tabs/pageState.ts");
const { goBackAcrossEngines, offerWebKit } = await import("./actions.ts");
const { dropSwap, useRetiringPages } = await import("./engineSwap.ts");

const S = () => useBrowser.getState();
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

function movedTab(url) {
  S().hydrate({});
  const w = S().createWindow({ url });
  const tabId = model.activeTabId(S(), w);
  S().updateTab(tabId, { engine: "webkit", url });
  patchPage(tabId, { engineBack: { engine: "chromium", url: "https://search.example/?q=film" } });
  return { w, tabId };
}

test("Back across engines asks first when the page has unsaved input, and staying keeps the page", async () => {
  const { tabId } = movedTab("https://www.netflix.com/browse");
  webviews.set(tabId, { evaluate: () => Promise.resolve(true) });
  assert.equal(await goBackAcrossEngines(tabId), false);
  assert.equal(S().tabs[tabId].engine, "webkit");
  assert.ok(pageOf(tabId).engineBack);
  webviews.clear();
});

test("Back across engines without unsaved input reopens the page before in its engine", async () => {
  const { tabId } = movedTab("https://www.netflix.com/browse");
  webviews.set(tabId, { evaluate: () => Promise.resolve(false) });
  assert.equal(await goBackAcrossEngines(tabId), true);
  assert.equal(S().tabs[tabId].engine, "chromium");
  assert.equal(S().tabs[tabId].page.nav.url, "https://search.example/?q=film");
  assert.equal(pageOf(tabId).engineBack, null);
  webviews.clear();
});

test("a streaming site moves to WebKit quietly: the old page is held until the new one paints, and Move Back stays in the tab's engine", async () => {
  S().hydrate({});
  S().updateSettings({ protectedVideoInWebKit: true });
  const w = S().createWindow({ url: "https://www.netflix.com/watch/1" });
  const tabId = model.activeTabId(S(), w);
  S().updateTab(tabId, { engine: "chromium", url: "https://www.netflix.com/watch/1" });
  webviews.set(tabId, { evaluate: () => Promise.resolve(false), pageCookies: () => Promise.resolve([]) });
  offerWebKit(tabId, { keySystem: "com.widevine.alpha", main: true });
  await settle();
  await settle();
  await settle();
  assert.equal(S().tabs[tabId].engine, "webkit");
  assert.deepEqual(useRetiringPages.getState()[tabId], { engine: "chromium" });
  dropSwap(tabId);
  assert.equal(useRetiringPages.getState()[tabId], undefined);
  assert.deepEqual(S().settings.websiteEngines, {});
  webviews.clear();
});
