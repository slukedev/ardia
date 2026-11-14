import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const swift = readFileSync(new URL("../ios/WebKitExtensionShim.swift", import.meta.url), "utf8");
const template = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'));
const APP = "dev.ardia.webkit";
assert.ok(swift.includes(`static let application = "${APP}"`));

function load(apis, { answer = () => ({ result: null }), extra = {} } = {}) {
  const sent = [];
  const ports = [];
  const tabs = new Map([
    [11, { id: 11, windowId: 7, index: 0, url: "https://a.example/" }],
    [12, { id: 12, windowId: 9, index: 1, url: "https://b.example/" }],
  ]);
  const browser = {
    runtime: {
      sendNativeMessage: async (application, message) => {
        sent.push({ application, message });
        return answer(message);
      },
      connectNative: (application) => {
        const port = { application, posted: [], onMessage: listenerSet(), onDisconnect: listenerSet(), postMessage: (m) => port.posted.push(m) };
        ports.push(port);
        return port;
      },
    },
    tabs: { get: async (id) => tabs.get(id), query: async () => [...tabs.values()] },
    windows: { getAll: async () => [{ id: 7 }, { id: 9 }], getCurrent: async () => ({ id: 9 }) },
    ...extra,
  };
  const context = { browser, chrome: browser, console, setTimeout, Promise, Object, Array, Set, Map, Error, JSON, String, Number };
  context.globalThis = context;
  vm.runInNewContext(template.replace("__ARDIA_APP__", JSON.stringify(APP)).replace("__ARDIA_APIS__", JSON.stringify(apis)), context);
  return { browser, sent, ports };
}

const plain = (value) => JSON.parse(JSON.stringify(value));

function listenerSet() {
  const set = new Set();
  return { addListener: (l) => set.add(l), fire: (...args) => [...set].forEach((l) => l(...args)) };
}

test("the shim adds only the APIs it was staged with, and never replaces one the engine has", () => {
  const ownHistory = { search: () => "engine" };
  const { browser } = load(["bookmarks", "history"], { extra: { history: ownHistory } });
  assert.equal(typeof browser.bookmarks.getTree, "function");
  assert.equal(browser.history, ownHistory);
  assert.equal(browser.downloads, undefined);
  assert.equal(browser.tabGroups, undefined);
});

test("a call goes to Ardia's application id and resolves with the reply, or rejects with its error, or answers a callback", async () => {
  let reply = { result: [{ id: "0", title: "" }] };
  const { browser, sent } = load(["bookmarks"], { answer: () => reply });
  assert.deepEqual(plain(await browser.bookmarks.getTree()), [{ id: "0", title: "" }]);
  assert.equal(sent[0].application, APP);
  assert.deepEqual(plain(sent[0].message), { ardia: 1, api: "bookmarks", method: "getTree", args: [], tabs: [] });
  reply = { error: "Can't find bookmark for id." };
  await assert.rejects(browser.bookmarks.get("99"), /Can't find bookmark/);
  reply = { result: { id: "5" } };
  const called = await new Promise((resolve) => assert.equal(browser.bookmarks.create({ title: "x" }, resolve), undefined));
  assert.deepEqual(plain(called), { id: "5" });
});

test("tab and window ids cross as positions the app can resolve, and window refs come back as the extension's window ids", async () => {
  const { browser, sent } = load(["tabGroups"], {
    answer: (m) => (m.method === "query" ? { result: [{ id: 3, windowId: { __windowTabs: ["t2"] } }], windows: [["t1"], ["t2", "t3"]] } : { result: 4 }),
  });
  assert.equal(await browser.tabs.group({ tabIds: [12, 11] }), 4);
  const group = plain(sent[0].message);
  assert.deepEqual(group.args, [{ tabIds: [{ __tab: 0 }, { __tab: 1 }] }]);
  assert.deepEqual(group.tabs, [
    { window: 1, index: 1, url: "https://b.example/" },
    { window: 0, index: 0, url: "https://a.example/" },
  ]);
  const groups = await browser.tabGroups.query({ windowId: -2 });
  assert.deepEqual(plain(sent[1].message.args), [{ windowId: { __window: 1 } }]);
  assert.equal(groups[0].windowId, 9);
});

test("tabs.query and tabs.get gain groupId, and tabs.query filters by it", async () => {
  const { browser } = load(["tabGroups"], { answer: (m) => (m.method === "groupIdsOf" ? { result: m.tabs.map((t) => (t.index === 1 ? 4 : -1)) } : { result: null }) });
  const all = await browser.tabs.query({});
  assert.deepEqual(plain(all.map((t) => t.groupId)), [-1, 4]);
  assert.deepEqual(plain((await browser.tabs.query({ groupId: 4 })).map((t) => t.id)), [12]);
  assert.equal((await browser.tabs.get(11)).groupId, -1);
});

test("listening opens one port to Ardia, says which APIs it wants, and hands events to the listeners", async () => {
  const { browser, ports } = load(["bookmarks", "downloads"]);
  const seen = [];
  const created = (id, node) => seen.push([id, node.title]);
  browser.bookmarks.onCreated.addListener(created);
  browser.downloads.onChanged.addListener(() => {});
  assert.equal(ports.length, 1);
  assert.equal(ports[0].application, APP);
  assert.deepEqual(plain(ports[0].posted.at(-1)), { ardia: 1, listen: ["bookmarks", "downloads"] });
  ports[0].onMessage.fire({ ardia: 1, api: "bookmarks", event: "onCreated", args: ["8", { title: "Docs" }], windows: [] });
  ports[0].onMessage.fire({ ardia: 1, api: "history", event: "onVisited", args: [{}] });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(seen, [["8", "Docs"]]);
  assert.equal(browser.bookmarks.onCreated.hasListener(created), true);
  browser.bookmarks.onCreated.removeListener(created);
  assert.deepEqual(plain(ports[0].posted.at(-1)), { ardia: 1, listen: ["downloads"] });
});

test("without sendNativeMessage (a content script or sandboxed page) the shim leaves the page alone", () => {
  const browser = { runtime: {} };
  const context = { browser, chrome: browser, Object };
  context.globalThis = context;
  vm.runInNewContext(template.replace("__ARDIA_APP__", JSON.stringify(APP)).replace("__ARDIA_APIS__", '["bookmarks"]'), context);
  assert.equal(browser.bookmarks, undefined);
});
