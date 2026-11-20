import assert from "node:assert/strict";
import { test } from "node:test";
import {
  builtInEngine,
  canSwitchEngine,
  chosenEngine,
  defaultEngine,
  engineForUrl,
  engineMark,
  engineUnderMode,
  modeEngineFor,
  offersEngineChoice,
  protectedVideoSite,
  recommendedEngineFor,
  ruleFor,
  siteOf,
  switchableEngine,
  tabEngine,
  typedNavigationEngine,
  visitRecorder,
} from "./engines.ts";
import { makeTab, snapshotTab } from "../browser/model.ts";

const tab = (id, patch = {}) => ({ id, url: "", page: { kind: "idle" }, openerId: null, ...patch });
const state = (tabs, settings = {}) => ({
  tabs: Object.fromEntries(tabs.map((t) => [t.id, t])),
  settings: { pageEngine: "chromium", websiteEngines: {}, ...settings },
});

test("a site is its scheme, host and port, and nothing else", () => {
  assert.equal(siteOf("https://www.Netflix.com/watch/1?x=2#y"), "https://www.netflix.com");
  assert.equal(siteOf("http://localhost:8080/a"), "http://localhost:8080");
  assert.equal(siteOf("https://example.com:443/"), "https://example.com");
  assert.equal(siteOf("ardia://settings"), null);
  assert.equal(siteOf("not a url"), null);
});

test("rules match the exact site, never its subdomains", () => {
  const s = state([], { websiteEngines: { "https://netflix.com": "webkit" } });
  assert.equal(ruleFor(s, "https://netflix.com/browse"), "webkit");
  assert.equal(ruleFor(s, "https://www.netflix.com/browse"), undefined);
  assert.equal(ruleFor(s, "http://netflix.com/"), undefined);
  assert.equal(engineForUrl(s, "https://www.netflix.com/"), "chromium");
  assert.equal(engineForUrl({ settings: { ...s.settings, pageEngine: "webkit" } }, "https://example.com/"), "webkit");
});

test("a tab keeps its engine, else follows its adoption, its opener, then rules", () => {
  const rules = { websiteEngines: { "https://www.netflix.com": "webkit" } };
  const s = state(
    [
      tab("fixed", { engine: "chromium", url: "https://www.netflix.com/" }),
      tab("popup", { page: { kind: "adopted", adopt: "webkit:3", nav: null } }),
      tab("chrome", { page: { kind: "adopted", adopt: "ardiacore:9", nav: null }, url: "https://www.netflix.com/" }),
      tab("opener", { engine: "webkit", url: "https://www.netflix.com/" }),
      tab("link", { openerId: "opener", url: "https://example.com/" }),
      tab("typed", { url: "https://www.netflix.com/" }),
      tab("copy", { page: { kind: "adopted", adopt: "clone:opener", nav: null } }),
    ],
    rules,
  );
  assert.equal(tabEngine(s, "fixed"), "chromium");
  assert.equal(tabEngine(s, "popup"), "webkit");
  assert.equal(tabEngine(s, "chrome"), "chromium");
  assert.equal(tabEngine(s, "link"), "webkit");
  assert.equal(tabEngine(s, "typed"), "webkit");
  assert.equal(tabEngine(s, "copy"), "webkit");
  assert.equal(tabEngine(s, "gone"), "chromium");
});

test("typing an address follows a rule, else keeps the page's engine", () => {
  const s = state([tab("w", { engine: "webkit", url: "https://www.netflix.com/" }), tab("blank")], { websiteEngines: { "https://www.youtube.com": "chromium" } });
  assert.equal(typedNavigationEngine(s, s.tabs.w, "https://www.youtube.com/"), "chromium");
  assert.equal(typedNavigationEngine(s, s.tabs.w, "https://example.com/"), "webkit");
  assert.equal(typedNavigationEngine(s, s.tabs.blank, "https://example.com/"), "chromium");
});

test("streaming sites open in WebKit when the setting is on, over https, subdomains included", () => {
  assert.equal(protectedVideoSite("https://www.netflix.com/watch/1"), true);
  assert.equal(protectedVideoSite("https://netflix.com/"), true);
  assert.equal(protectedVideoSite("https://open.spotify.com/track/1"), true);
  assert.equal(protectedVideoSite("https://www.spotify.com/"), false);
  assert.equal(protectedVideoSite("https://netflix.com.example.com/"), false);
  assert.equal(protectedVideoSite("https://notnetflix.com/"), false);
  assert.equal(protectedVideoSite("http://www.netflix.com/"), false);
  assert.equal(protectedVideoSite("https://v.qq.com/x/cover/1.html"), true);
  assert.equal(protectedVideoSite("https://mail.qq.com/"), false);
  const off = state([]);
  const on = state([tab("typed", { url: "https://www.netflix.com/" }), tab("page", { engine: "chromium", url: "https://example.com/" })], { protectedVideoInWebKit: true });
  assert.equal(chosenEngine(off, "https://www.netflix.com/"), undefined);
  assert.equal(engineForUrl(on, "https://www.netflix.com/browse"), "webkit");
  assert.equal(tabEngine(on, "typed"), "webkit");
  assert.equal(typedNavigationEngine(on, on.tabs.page, "https://www.disneyplus.com/"), "webkit");
  assert.equal(recommendedEngineFor(on, "https://www.netflix.com/"), "webkit");
  assert.equal(recommendedEngineFor(on, "https://example.com/"), "chromium");
});

test("Spotify's player opens in WebKit with the streaming sites, and a rule still wins", () => {
  const spotify = "https://open.spotify.com/track/1";
  assert.equal(engineForUrl(state([], { protectedVideoInWebKit: true }), spotify), "webkit");
  assert.equal(recommendedEngineFor(state([], { protectedVideoInWebKit: true }), spotify), "webkit");
  assert.equal(engineForUrl(state([], { protectedVideoInWebKit: true }), "http://open.spotify.com/"), "chromium");
  assert.equal(engineForUrl(state([], { protectedVideoInWebKit: true }), "https://www.spotify.com/"), "chromium");
  assert.equal(engineForUrl(state([], { protectedVideoInWebKit: true, websiteEngines: { "https://open.spotify.com": "chromium" } }), spotify), "chromium");
  assert.equal(engineForUrl(state([], { protectedVideoInWebKit: false }), spotify), "chromium");
});

test("a website rule wins over the streaming default", () => {
  const s = state([], { protectedVideoInWebKit: true, websiteEngines: { "https://www.netflix.com": "chromium" } });
  assert.equal(chosenEngine(s, "https://www.netflix.com/"), "chromium");
  assert.equal(engineForUrl(s, "https://www.netflix.com/"), "chromium");
  assert.equal(engineForUrl(s, "https://netflix.com/"), "webkit");
  assert.equal(ruleFor(s, "https://netflix.com/"), undefined);
});

test("Chromium's own pages always open in Chromium", () => {
  const s = state([tab("v", { engine: "webkit", url: "ardia://version" }), tab("w", { engine: "webkit", url: "https://a.com/" })], { pageEngine: "webkit" });
  assert.equal(tabEngine(s, "v"), "chromium");
  assert.equal(typedNavigationEngine(s, s.tabs.w, "ardia://extensions"), "chromium");
  assert.equal(typedNavigationEngine(s, s.tabs.w, "chrome-extension://abc/options.html"), "chromium");
});

test("the mark shows only on web pages away from the default engine, and never with one engine for every page", () => {
  const tabs = [tab("w", { engine: "webkit", url: "https://a.com/" }), tab("c", { engine: "chromium", url: "https://a.com/" }), tab("n", { engine: "webkit", url: "ardia://history" })];
  const s = state(tabs);
  assert.equal(engineMark(s, "w"), "webkit");
  assert.equal(engineMark(s, "c"), null);
  assert.equal(engineMark(s, "n"), null);
  assert.equal(engineMark(state(tabs, { engineMode: "webkit" }), "w"), null);
  assert.equal(engineMark(state(tabs, { engineMode: "chromium" }), "w"), null);
});

test("a closed WebKit tab reopens in WebKit, whatever restore id it carries", () => {
  const closed = snapshotTab({ ...makeTab("w1", "default", "https://www.netflix.com/"), engine: "webkit" });
  assert.equal(closed.engine, "webkit");
  const reopened = { ...makeTab("w1", "default", closed.url, closed), page: { kind: "adopted", adopt: "restore:old", nav: null } };
  const s = state([reopened]);
  assert.equal(tabEngine(s, reopened.id), "webkit");
  assert.equal(snapshotTab(makeTab("w1", "default", "https://a.com/")).engine, undefined);
});

test("Chromium only opens every page in Chromium: no rules, no streaming sites, no WebKit adoption", () => {
  const rules = { websiteEngines: { "https://a.com": "webkit" }, protectedVideoInWebKit: true, pageEngine: "webkit", engineMode: "chromium" };
  const s = state(
    [
      tab("kept", { engine: "webkit", url: "https://b.com/" }),
      tab("popup", { url: "https://c.com/", page: { kind: "adopted", adopt: "webkit:1", nav: null } }),
      tab("fresh", { url: "https://www.netflix.com/" }),
    ],
    rules,
  );
  for (const id of ["kept", "popup", "fresh"]) assert.equal(tabEngine(s, id), "chromium", id);
  assert.equal(engineForUrl(s, "https://a.com/"), "chromium");
  assert.equal(chosenEngine(s, "https://www.netflix.com/"), "chromium");
  assert.equal(builtInEngine(s, "https://www.netflix.com/"), undefined);
  assert.equal(ruleFor(s, "https://a.com/"), undefined);
  assert.equal(defaultEngine(s), "chromium");
  assert.equal(typedNavigationEngine(s, s.tabs.kept, "https://a.com/"), "chromium");
  assert.equal(switchableEngine(s, "https://a.com/"), false);
  assert.equal(switchableEngine(state([], {}), "https://a.com/"), true);
});

test("WebKit only opens every web page in WebKit, and keeps browser pages, the Web Store and Chrome-driven tabs on Chromium", () => {
  const s = state(
    [
      tab("kept", { engine: "chromium", url: "https://b.com/" }),
      tab("rule", { url: "https://a.com/" }),
      tab("blank"),
      tab("restored", { engine: "chromium", url: "https://d.com/", page: { kind: "adopted", adopt: "restore:9", nav: null } }),
      tab("internal", { url: "chrome://extensions/", page: { kind: "loaded", nav: { url: "chrome://extensions/", seq: 1 } } }),
      tab("store", { url: "https://chromewebstore.google.com/detail/abc" }),
      tab("cli", { engine: "chromium", url: "https://e.com/", page: { kind: "adopted", adopt: "tab:7", nav: null } }),
      tab("cliPopup", { url: "https://f.com/", openerId: "cli", page: { kind: "adopted", adopt: "ardiacore:8", nav: null } }),
      tab("pagePopup", { url: "https://g.com/", openerId: "internal", page: { kind: "adopted", adopt: "ardiacore:9", nav: null } }),
    ],
    { engineMode: "webkit", websiteEngines: { "https://a.com": "chromium" } },
  );
  for (const id of ["kept", "rule", "blank", "restored", "pagePopup"]) assert.equal(tabEngine(s, id), "webkit", id);
  for (const id of ["internal", "store", "cli", "cliPopup"]) assert.equal(tabEngine(s, id), "chromium", id);
  assert.equal(typedNavigationEngine(s, s.tabs.cli, "https://a.com/"), "webkit");
  assert.equal(typedNavigationEngine(s, s.tabs.kept, "https://chromewebstore.google.com/"), "chromium");
  assert.equal(recommendedEngineFor(s, "https://www.netflix.com/"), "webkit");
  assert.equal(modeEngineFor(s, s.tabs.internal, "https://x.com/"), "webkit");
  assert.equal(modeEngineFor(s, s.tabs.cli, "https://x.com/"), "chromium");
  assert.equal(modeEngineFor(state([], {}), s.tabs.kept, "https://x.com/"), undefined);
});

test("leaving a single-engine mode puts each tab back where Automatic would open it", () => {
  const s = state([tab("a", { engine: "webkit", url: "https://a.com/" }), tab("n", { engine: "webkit", url: "https://www.netflix.com/" }), tab("x", { engine: "webkit", url: "chrome://version" }), tab("login", { engine: "webkit", openerId: "n", url: "https://login.example/" }), tab("oauth", { engine: "webkit", openerId: "a", url: "https://login.example/" })], {
    protectedVideoInWebKit: true,
    engineMode: "automatic",
  });
  assert.equal(engineUnderMode(s, s.tabs.a), "chromium");
  assert.equal(engineUnderMode(s, s.tabs.n), "webkit");
  assert.equal(engineUnderMode(s, s.tabs.x), "chromium");
  assert.equal(engineUnderMode(s, s.tabs.login), "chromium", "a reloaded tab follows its own site, not the tab that opened it");
  assert.equal(engineUnderMode(s, s.tabs.oauth), "chromium");
  assert.equal(tabEngine(s, "a"), "webkit");
});

test("leaving a single-engine mode keeps a page-opened popup on its opener's engine, so window.opener survives", () => {
  const s = state([
    tab("n", { engine: "webkit", url: "https://www.netflix.com/" }),
    tab("signIn", { engine: "webkit", openerId: "n", url: "https://accounts.example/authorize", page: { kind: "adopted", adopt: "webkit:7" } }),
    tab("typed", { engine: "webkit", openerId: "n", url: "https://accounts.example/authorize", page: { kind: "loaded", nav: { url: "https://accounts.example/authorize", seq: 1 } } }),
    tab("orphan", { engine: "webkit", openerId: "gone", url: "https://accounts.example/authorize", page: { kind: "adopted", adopt: "webkit:8" } }),
  ], { protectedVideoInWebKit: true, engineMode: "automatic" });
  assert.equal(engineUnderMode(s, s.tabs.n), "webkit");
  assert.equal(engineUnderMode(s, s.tabs.signIn), "webkit", "a window.open popup stays with its opener");
  assert.equal(engineUnderMode(s, s.tabs.typed), "chromium", "a tab only opened from a link follows its own site");
  assert.equal(engineUnderMode(s, s.tabs.orphan), "chromium", "a popup whose opener closed follows its own site");
});

test("the Web Store always opens in Chromium, which installs its extensions", () => {
  const s = state([tab("w", { engine: "webkit", url: "https://chromewebstore.google.com/detail/x" })], { pageEngine: "webkit" });
  assert.equal(tabEngine(s, "w"), "chromium");
  assert.equal(chosenEngine(s, "https://chromewebstore.google.com/"), "chromium");
  assert.equal(canSwitchEngine("https://chromewebstore.google.com/detail/x"), false);
  assert.equal(canSwitchEngine("https://chromewebstore.google.com.evil.example/"), true);
});

function recorder() {
  const written = [];
  let clock = 0;
  let next = 0;
  const pending = new Map();
  const visits = visitRecorder((profile, visit) => written.push({ profile, ...visit }), { set: (run, ms) => (pending.set(++next, { run, at: clock + ms }), next), clear: (id) => pending.delete(id) }, () => clock);
  const advance = (ms) => {
    clock += ms;
    for (const [id, timer] of [...pending]) if (timer.at <= clock) (pending.delete(id), timer.run());
  };
  const page = (url, title, isLoading, committedUrl = url) => ({ url, title, isLoading, committedUrl });
  return { visits, written, advance, page };
}

test("a WebKit visit is recorded for the committed page, with that page's own title", () => {
  const { visits, written, advance, page } = recorder();
  visits.note("t", "", page("https://b.com/", "A's title", true, "https://a.com/"));
  advance(1);
  visits.note("t", "", page("https://b.com/", "A's title", true));
  visits.note("t", "", page("https://b.com/", "", true));
  assert.deepEqual(written, []);
  advance(1);
  visits.note("t", "", page("https://b.com/", "B's title", true));
  visits.note("t", "", page("https://b.com/", "B again", false));
  assert.deepEqual(written, [{ profile: "", url: "https://b.com/", title: "B's title", at: 1 }]);
});

test("a page whose title never changes is recorded once it settles, not at once", () => {
  const { visits, written, advance, page } = recorder();
  visits.note("t", "", page("https://b.com/", "Same", false));
  assert.deepEqual(written, []);
  advance(1500);
  assert.deepEqual(written, [{ profile: "", url: "https://b.com/", title: "Same", at: 0 }]);
});

test("a navigation that became a download, or an error page, is never recorded", () => {
  const { visits, written, advance, page } = recorder();
  visits.note("t", "", page("https://f.com/file.zip", "", false, ""));
  visits.note("t", "", page("https://f.com/file.zip", "x", false, "https://a.com/"));
  advance(5000);
  assert.deepEqual(written, []);
});

test("a visit keeps the profile it was made in, even if the tab moves before it settles", () => {
  const { visits, written, advance, page } = recorder();
  visits.note("t", "work", page("https://a.com/", "A", false));
  visits.note("t", "home", page("https://a.com/", "A", false));
  advance(1500);
  assert.deepEqual(written.map((v) => v.profile), ["work"]);
});

test("one visit's settle timer never records the next visit", () => {
  const { visits, written, advance, page } = recorder();
  visits.note("t", "", page("https://a.com/", "A", false));
  advance(1400);
  visits.note("t", "", page("https://b.com/", "A", true));
  advance(100);
  assert.deepEqual(written, [{ profile: "", url: "https://a.com/", title: "A", at: 0 }]);
  advance(1000);
  visits.note("t", "", page("https://b.com/", "B", false));
  assert.deepEqual(written.at(-1), { profile: "", url: "https://b.com/", title: "B", at: 1400 });
});

test("a quick next page still records the one before it, with its own title and time", () => {
  const { visits, written, page, advance } = recorder();
  visits.note("t", "", page("https://a.com/", "Old", true));
  advance(200);
  visits.note("t", "", page("https://a.com/#two", "Old", false));
  assert.deepEqual(written, [{ profile: "", url: "https://a.com/", title: "Old", at: 0 }]);
});

test("a private visit is never written, and a reload of the same page isn't a new visit", () => {
  const { visits, written, page, advance } = recorder();
  visits.note("p", null, page("https://a.com/", "A", false));
  advance(1500);
  visits.note("t", "", page("https://a.com/", "A", false));
  advance(1500);
  visits.note("t", "", page("https://a.com/", "A", true));
  visits.note("t", "", page("https://a.com/", "A", false));
  advance(1500);
  assert.deepEqual(written.length, 1);
});

test("closing a tab records its unsettled visit and forgets the tab", () => {
  const { visits, written, advance, page } = recorder();
  visits.note("t", "", page("https://a.com/", "Old", true));
  visits.close("t");
  assert.deepEqual(written, [{ profile: "", url: "https://a.com/", title: "Old", at: 0 }]);
  assert.equal(visits.size(), 0);
  advance(5000);
  assert.equal(written.length, 1);
});

test("many tabs don't make an open tab record its page again", () => {
  const { visits, written, advance, page } = recorder();
  visits.note("keep", "", page("https://keep.com/", "K", false));
  advance(1500);
  for (let i = 0; i < 1200; i++) {
    visits.note(`t${i}`, "", page(`https://s${i}.com/`, "", false));
    advance(1500);
    visits.close(`t${i}`);
  }
  visits.note("keep", "", page("https://keep.com/", "K", false));
  advance(1500);
  assert.equal(written.filter((v) => v.url === "https://keep.com/").length, 1);
  assert.equal(visits.size(), 1);
});

test("the Mac always offers a page engine choice, so Site Controls keeps Opens in for every page, local files included", () => {
  assert.equal(offersEngineChoice(), true);
});
