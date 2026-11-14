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
const { followSiteChoice, goBackAcrossEngines, offerWebKit, openPageIn, setEngineMode, useEngineModeSwitch, useEngineOffers } = await import("./actions.ts");
const { tabEngine } = await import("./engines.ts");
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

function liveTab(url, engine, unsaved = false) {
  const w = S().createWindow({ url });
  const tabId = model.activeTabId(S(), w);
  S().updateTab(tabId, { engine, url });
  webviews.set(tabId, { evaluate: (script) => Promise.resolve(script.includes("defaultValue") ? unsaved : false), pageCookies: () => Promise.resolve([]) });
  return tabId;
}

test("WebKit only moves every open page there, holding each old page until the new one paints", async () => {
  S().hydrate({});
  const a = liveTab("https://a.com/", "chromium");
  const b = liveTab("https://b.com/", "chromium");
  patchPage(a, { engineBack: { engine: "webkit", url: "https://z.com/" } });
  const switching = setEngineMode("webkit");
  assert.equal(useEngineModeSwitch.getState().pending, "webkit");
  assert.equal(await switching, true);
  assert.equal(S().settings.engineMode, "webkit");
  for (const id of [a, b]) {
    assert.equal(S().tabs[id].engine, "webkit");
    assert.equal(tabEngine(S(), id), "webkit");
    assert.deepEqual(useRetiringPages.getState()[id], { engine: "chromium" });
    dropSwap(id);
  }
  assert.equal(S().tabs[a].page.nav.url, "https://a.com/");
  assert.equal(pageOf(a).engineBack, null);
  assert.equal(useEngineModeSwitch.getState().pending, null);
  webviews.clear();
});

test("a mode change asks once when a page has unsaved input, and Cancel leaves the mode and every tab alone", async () => {
  S().hydrate({});
  const a = liveTab("https://a.com/", "chromium", true);
  assert.equal(await setEngineMode("webkit"), false);
  assert.equal(S().settings.engineMode, "automatic");
  assert.equal(S().tabs[a].engine, "chromium");
  assert.equal(useRetiringPages.getState()[a], undefined);
  webviews.clear();
});

test("Chromium only offers no WebKit move for protected video and refuses a move to WebKit, and Automatic puts the streaming site back", async () => {
  S().hydrate({});
  const a = liveTab("https://www.netflix.com/watch/1", "webkit");
  assert.equal(await setEngineMode("chromium"), true);
  dropSwap(a);
  assert.equal(tabEngine(S(), a), "chromium");
  offerWebKit(a, { keySystem: "com.widevine.alpha", main: true });
  await settle();
  assert.deepEqual(useEngineOffers.getState(), {});
  assert.equal(await openPageIn(a, "webkit"), false);
  assert.equal(tabEngine(S(), a), "chromium");
  assert.equal(await setEngineMode("automatic"), true);
  dropSwap(a);
  assert.equal(tabEngine(S(), a), "webkit");
  webviews.clear();
});

test("in WebKit only, a link from a Chromium page to a website moves the tab to WebKit with Back to the page before", async () => {
  S().hydrate({});
  S().updateSettings({ engineMode: "webkit" });
  const w = S().createWindow({ url: "chrome://extensions/" });
  const tabId = model.activeTabId(S(), w);
  webviews.set(tabId, { evaluate: () => Promise.resolve(false), pageCookies: () => Promise.resolve([]) });
  assert.equal(tabEngine(S(), tabId), "chromium");
  S().updateTab(tabId, { url: "https://developer.chrome.com/docs" });
  followSiteChoice(tabId, "chromium", "https://developer.chrome.com/docs", "chrome://extensions/");
  for (let i = 0; i < 6; i++) await settle();
  assert.equal(tabEngine(S(), tabId), "webkit");
  assert.equal(S().tabs[tabId].page.nav.url, "https://developer.chrome.com/docs");
  assert.deepEqual(pageOf(tabId).engineBack, { engine: "chromium", url: "chrome://extensions/" });
  dropSwap(tabId);
  webviews.clear();
});

test("in WebKit only, a link from a website into the Web Store moves to Chromium, and the Web Store's own links stay there", async () => {
  S().hydrate({});
  S().updateSettings({ engineMode: "webkit" });
  const w = S().createWindow({ url: "https://blog.example/" });
  const tabId = model.activeTabId(S(), w);
  webviews.set(tabId, { evaluate: () => Promise.resolve(false), pageCookies: () => Promise.resolve([]) });
  assert.equal(tabEngine(S(), tabId), "webkit");
  S().updateTab(tabId, { url: "https://chromewebstore.google.com/detail/abc" });
  followSiteChoice(tabId, "webkit", "https://chromewebstore.google.com/detail/abc", "https://blog.example/");
  for (let i = 0; i < 6; i++) await settle();
  assert.equal(tabEngine(S(), tabId), "chromium");
  dropSwap(tabId);
  S().updateTab(tabId, { url: "https://accounts.google.com/signin" });
  followSiteChoice(tabId, "chromium", "https://accounts.google.com/signin", "https://chromewebstore.google.com/detail/abc");
  for (let i = 0; i < 6; i++) await settle();
  assert.equal(tabEngine(S(), tabId), "chromium");
  assert.equal(useRetiringPages.getState()[tabId], undefined);
  webviews.clear();
});

const { persistEngine } = await import("./actions.ts");
const { flushPersistence, loadSession, startPersistence } = await import("../session/persist.ts");
const stub = await import("../../test-native/index.ts");

function chromeMadeTab() {
  const w = S().createWindow({ url: "https://first.example/" });
  const tabId = model.activeTabId(S(), w);
  S().updateTab(tabId, { url: "https://cli.example/", page: { kind: "adopted", adopt: "tab:42", nav: null } });
  persistEngine(tabId, "chromium");
  return tabId;
}

test("in WebKit only, a tab Chrome opened (CDP or an extension) wakes from sleep and comes back after relaunch in Chromium", () => {
  stub.docs.clear();
  S().hydrate({});
  S().updateSettings({ engineMode: "webkit" });
  const stop = startPersistence();
  const tabId = chromeMadeTab();
  assert.equal(S().tabs[tabId].chromeOpened, true);
  assert.equal(tabEngine(S(), tabId), "chromium");
  S().updateTab(tabId, { page: { kind: "asleep" } });
  assert.equal(tabEngine(S(), tabId), "chromium");
  flushPersistence();
  stop();
  S().hydrate(loadSession());
  assert.equal(S().tabs[tabId].chromeOpened, true);
  assert.equal(S().tabs[tabId].page.kind === "adopted", false);
  assert.equal(tabEngine(S(), tabId), "chromium");
});

test("a page opened by a Chrome-opened tab is marked too, and typing an address in either moves it to WebKit", () => {
  S().hydrate({});
  S().updateSettings({ engineMode: "webkit" });
  const opener = chromeMadeTab();
  const w = S().tabs[opener].windowId;
  const popup = S().newTab(w, { url: "https://popup.example/", adoptId: "ardiacore:5", openerId: opener });
  persistEngine(popup, "chromium");
  assert.equal(S().tabs[popup].chromeOpened, true);
  S().updateTab(popup, { page: { kind: "asleep" }, openerId: null });
  assert.equal(tabEngine(S(), popup), "chromium");
  S().navigate(opener, "https://typed.example/", { userInitiated: true });
  assert.equal(S().tabs[opener].chromeOpened, undefined);
  assert.equal(tabEngine(S(), opener), "webkit");
});

test("a tab the app opened is never marked as Chrome's", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://mine.example/" });
  const tabId = model.activeTabId(S(), w);
  persistEngine(tabId, "chromium");
  assert.equal(S().tabs[tabId].chromeOpened, undefined);
  S().updateSettings({ engineMode: "webkit" });
  assert.equal(tabEngine(S(), tabId), "webkit");
});
