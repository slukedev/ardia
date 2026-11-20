import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { webKitMediaBridge, webKitPageScript } from "./webkit-page-source.mjs";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const pageScript = read("../ios/page_script.js");
const webKitScript = `${webKitPageScript}\n${webKitMediaBridge}`;
const between = (text, from, to) => {
  const start = text.indexOf(from);
  const end = text.indexOf(to, start);
  assert.ok(start >= 0 && end > start, `${from} … ${to} not found`);
  return text.slice(start, end).split("\n").map((line) => line.trim()).filter(Boolean).join("\n");
};

test("WebKit's page script decides scroll direction with page_script.js's code and thresholds", () => {
  const scroll = (text) => between(text, "const scrollDirection = () => {", "const direction = scrollDirection();");
  assert.equal(scroll(webKitScript), scroll(pageScript));
});

test("WebKit's page script feeds the scroll detector the page's input the way page_script.js does", () => {
  const wiring = (text) => between(text, "const direction = scrollDirection();", "const measureScroll = ");
  assert.equal(wiring(webKitScript), wiring(pageScript));
});

test("WebKit's page script measures scrolling the way page_script.js does", () => {
  const measure = (text) =>
    between(text, "const target = scrollTarget;", "addEventListener(\"resize\"").replace(/\b(send|post)\("scroll"/, "report(\"scroll\"").replace(/\n?try \{|\n?\} catch \(e\) \{\}\n?\};|\n?\}\);/g, "");
  assert.equal(measure(webKitScript), measure(pageScript));
});

test("WebKit's page script samples the page's theme with page_script.js's code, thresholds and scheduling", () => {
  const theme = (text) => between(text, "const parse = (css) => {", "if (window.visualViewport)");
  const webKitTheme = between(webKitScript, "const parse = (css) => {", "const scrollDirection = () => {").replace(/\n\} catch \(e\) \{\}\nif \(isTop\) \{$/, "");
  assert.equal(webKitTheme, theme(pageScript));
});

test("WebKit's page script reports selections for the popover with page_script.js's code", () => {
  const selection = (text) => between(text, "let selectionShown = false;", "handlers.selectionPopover(true);");
  assert.equal(selection(webKitScript), selection(pageScript));
});

test("WebKit's page world shims the app badge with page_script.js's code", () => {
  const badge = (text) => between(text, "const navigatorProto = window.Navigator.prototype;", 'install("clearAppBadge"');
  const disguise = (text) => between(text, "const asNative = (native, call) => {", "return disguised;");
  assert.equal(badge(webKitScript), badge(pageScript));
  assert.equal(disguise(webKitScript), disguise(pageScript));
});

test("WebKit's page script reports a link dropped on its own page with page_script.js's code", () => {
  const linkDrop = (text) => between(text, "const DRAG_MIN = 40;", "} catch (e) {}");
  assert.equal(linkDrop(webKitScript), linkDrop(pageScript));
});

function livePage({ top = true } = {}) {
  const posted = [];
  const timers = [];
  const frames = [];
  const listeners = [];
  const observers = [];
  const metaReads = { count: 0 };
  const listen = (target) => (type, fn) => listeners.push({ target, type, fn });
  const style = { color: "", backgroundColor: "rgb(255, 255, 255)", position: "static", colorScheme: "normal", scrollSnapType: "none", writingMode: "horizontal-tb" };
  const element = (nodeName) => ({ nodeName, style: {}, parentElement: null, getAttribute: () => null, appendChild() {}, remove() {}, isContentEditable: false });
  const html = element("HTML");
  const body = element("BODY");
  const head = element("HEAD");
  const meta = { ...element("META"), getAttribute: (name) => (name === "content" ? "#336699" : null) };
  const document = {
    readyState: "complete",
    documentElement: html,
    body,
    head,
    scrollingElement: html,
    addEventListener: listen("document"),
    removeEventListener() {},
    dispatchEvent: () => true,
    querySelectorAll(selector) {
      if (selector === 'meta[name="theme-color"]') {
        metaReads.count++;
        return [meta];
      }
      return [];
    },
    createElement: () => {
      const probe = element("SPAN");
      Object.defineProperty(probe.style, "color", { set(v) { this._color = v; }, get() { return this._color; } });
      return probe;
    },
    elementFromPoint: () => null,
  };
  class MutationObserver {
    constructor(callback) {
      this.callback = callback;
      observers.push(this);
    }
    observe() {}
  }
  const window = {
    document,
    location: { protocol: "https:", hostname: "example.test", origin: "https://example.test" },
    navigator: {},
    innerWidth: 1000,
    innerHeight: 800,
    scrollY: 0,
    performance: { now: () => 0 },
    addEventListener: listen("window"),
    setTimeout: (fn) => timers.push(fn),
    clearTimeout() {},
    requestAnimationFrame: (fn) => frames.push(fn),
    getComputedStyle: (el) => (el && el.nodeName === "SPAN" ? { ...style, color: "rgb(51, 102, 153)" } : style),
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    getSelection: () => null,
    MutationObserver,
    HTMLMediaElement: class {},
    HTMLVideoElement: class {},
    HTMLAnchorElement: class {},
    Event: class {},
    Node: class {},
    MouseEvent: class {},
    DragEvent: class {},
    DataTransfer: class {},
    Element: class {},
    EventTarget: class {},
    webkit: { messageHandlers: { ardia: { postMessage: (message) => posted.push(JSON.parse(JSON.stringify(message))) } } },
  };
  window.window = window;
  window.top = top ? window : {};
  const run = (code) => runInNewContext(code, window);
  run(webKitPageScript.replace("\\#(WebKitMediaFaults.sitesJSON)", "[]"));
  const flush = () => {
    for (let round = 0; round < 10 && (timers.length || frames.length); round++) {
      for (const fn of timers.splice(0)) fn();
      for (const fn of frames.splice(0)) fn();
    }
  };
  const fire = (target, type, event = {}) => {
    for (const l of listeners) if (l.target === target && l.type === type) l.fn({ type, ...event });
  };
  const mutate = (records) => observers.forEach((o) => o.callback(records));
  return { posted, flush, fire, mutate, metaReads, html, meta };
}

test("a page that restyles its root on every frame doesn't make the theme reread its theme-color tags", () => {
  const page = livePage();
  page.flush();
  const reads = page.metaReads.count;
  assert.ok(reads >= 1);
  for (let frame = 0; frame < 60; frame++) {
    page.mutate([{ type: "attributes", target: page.html, attributeName: "style", oldValue: `--y: ${frame}` }]);
    page.flush();
  }
  assert.equal(page.metaReads.count, reads);
  page.mutate([{ type: "childList", target: {}, addedNodes: [page.meta], removedNodes: [] }]);
  page.flush();
  assert.equal(page.metaReads.count, reads + 1);
});

test("a frame that goes away stops counting as playing and drops its now playing entry", () => {
  const page = livePage({ top: false });
  page.fire("window", "pagehide", { persisted: false });
  const sent = page.posted.map(({ kind, data }) => ({ kind, data }));
  assert.deepEqual(sent.slice(-2), [
    { kind: "media", data: { playing: false, muted: false } },
    { kind: "nowPlaying", data: null },
  ]);
  const topPage = livePage();
  const before = topPage.posted.length;
  topPage.fire("window", "pagehide", { persisted: false });
  assert.equal(topPage.posted.slice(before).some(({ kind }) => kind === "media" || kind === "nowPlaying"), false);
});
