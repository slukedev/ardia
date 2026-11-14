import assert from "node:assert/strict";
import { test } from "node:test";
import { nativeEvents } from "../../test-native/events.ts";

const channel = nativeEvents();
const replies = new Map();
const sentEvents = [];
const synced = [];
globalThis.acTestNativeModules = {
  ...globalThis.acTestNativeModules,
  ArdiaWebKit: {
    call: (verb, profile, json) => {
      const args = JSON.parse(json);
      if (verb === "extensionReply") replies.set(args.id, args.reply);
      if (verb === "extensionEvent") sentEvents.push({ profile, ...args.event });
      if (verb === "syncExtensions") synced.push(profile);
      return Promise.resolve(verb === "syncExtensions" ? JSON.stringify({ available: true, loaded: [], failed: [] }) : "null");
    },
    addListener: channel.addListener,
  },
};

const { useBrowser } = await import("../browser/store.ts");
const model = await import("../browser/model.ts");
await import("./webKitExtensions.ts");
const { takeEngineSwitchCounts } = await import("../telemetry/engineSwitchCounts.ts");

const S = () => useBrowser.getState();
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const emit = (name, data) => channel.emit("webKit", { name, data });
let calls = 0;

async function ask(api, method, args = [], extra = {}) {
  const id = `t${++calls}`;
  emit("webKit.extensionCall", { id, profile: "", base: "", private: false, extensionId: "abc", api, method, args, tabKeys: [], windows: [], ...extra });
  for (let i = 0; i < 50 && !replies.has(id); i++) await tick();
  const reply = replies.get(id);
  assert.ok(reply, `${api}.${method} answered`);
  if ("error" in reply) throw new Error(reply.error);
  return reply.result;
}

function windowWithTabs(...urls) {
  S().hydrate({});
  const w = S().createWindow({ url: urls[0] });
  const first = model.activeTabId(S(), w);
  const rest = urls.slice(1).map((url) => S().newTab(w, { url }));
  return { w, tabs: [first, ...rest] };
}

const listen = (apis) => emit("webKit.extensionListeners", { profile: "", base: "", private: false, apis });

test("bookmarks read and write the app's own bookmarks, with Chrome's root ids, and refuse what Chrome refuses", async () => {
  windowWithTabs("https://home.example/");
  const folder = await ask("bookmarks", "create", [{ parentId: "1", title: "Work" }]);
  assert.equal(folder.parentId, "1");
  const link = await ask("bookmarks", "create", [{ title: "Docs", url: "https://docs.example/" }]);
  assert.equal(link.parentId, "2", "Chrome files a bookmark without a parent under Other Bookmarks");
  const moved = await ask("bookmarks", "move", [link.id, { parentId: folder.id, index: 0 }]);
  assert.deepEqual([moved.parentId, moved.index], [folder.id, 0]);
  assert.equal(S().bookmarks.nodes[link.id].parentId, folder.id);
  const [tree] = await ask("bookmarks", "getTree");
  assert.deepEqual(tree.children.map((c) => [c.id, c.folderType]), [["1", "bookmarks-bar"], ["2", "other"]]);
  assert.equal(tree.children[0].children[0].children[0].url, "https://docs.example/");
  assert.deepEqual((await ask("bookmarks", "search", ["docs"])).map((b) => b.id), [link.id]);
  await ask("bookmarks", "update", [link.id, { title: "Team Docs" }]);
  assert.equal(S().bookmarks.nodes[link.id].title, "Team Docs");
  await assert.rejects(ask("bookmarks", "remove", [folder.id]), /non-empty folder/);
  await assert.rejects(ask("bookmarks", "update", ["1", { title: "Mine" }]), /root bookmark folders/);
  await assert.rejects(ask("bookmarks", "get", ["nope"]), /Can't find bookmark/);
  await ask("bookmarks", "removeTree", [folder.id]);
  assert.equal(S().bookmarks.nodes[folder.id], undefined);
  assert.equal(S().bookmarks.nodes[link.id], undefined);
});

test("tab groups act on the sidebar's groups through the tabs the extension names, and report changes", async () => {
  const { w, tabs } = windowWithTabs("https://a.example/", "https://b.example/", "https://c.example/");
  sentEvents.length = 0;
  listen(["tabGroups"]);
  const windows = [[tabs[0], tabs[1], tabs[2]]];
  const groupId = await ask("tabGroups", "group", [{ tabIds: [{ __tab: 0 }, { __tab: 1 }] }], { tabKeys: [tabs[0], tabs[1]], windows });
  assert.equal(typeof groupId, "number");
  const group = Object.values(S().groups).find((g) => g.tabIds.includes(tabs[0]));
  assert.deepEqual([...group.tabIds].sort(), [tabs[0], tabs[1]].sort());
  assert.equal(group.pinned, false);
  assert.deepEqual(await ask("tabGroups", "groupIdsOf", [], { tabKeys: tabs }), [groupId, groupId, -1]);
  const updated = await ask("tabGroups", "update", [groupId, { title: "Research", color: "cyan", collapsed: true }]);
  assert.deepEqual([updated.title, updated.color, updated.collapsed], ["Research", "cyan", true]);
  assert.deepEqual(updated.windowId.__windowTabs.sort(), [...S().windows[w].tabIds].sort());
  assert.equal((await ask("tabGroups", "query", [{ windowId: { __window: 0 } }], { windows })).length, 1);
  assert.equal((await ask("tabGroups", "query", [{ color: "red" }])).length, 0);
  await ask("tabGroups", "ungroup", [{ tabIds: [{ __tab: 0 }, { __tab: 1 }] }], { tabKeys: [tabs[0], tabs[1]] });
  assert.equal(Object.values(S().groups).length, 0);
  await tick();
  assert.deepEqual(sentEvents.map((e) => e.event), ["onCreated", "onUpdated", "onRemoved"]);
  assert.ok(sentEvents.every((e) => e.api === "tabGroups" && e.profile === ""));
  await assert.rejects(ask("tabGroups", "get", [groupId]), /No group with id/);
  listen([]);
});

const download = (over) => ({ id: "wk-download-1", url: "https://files.example/a.zip", filename: "a.zip", path: "/tmp/a.zip", state: "downloading", paused: false, received: 10, total: 100, speed: 0, mimeType: "application/zip", profile: "", ...over });

test("downloads list the profile's downloads under stable numbers, follow their changes and wait for the one an extension started", async () => {
  windowWithTabs("https://home.example/");
  sentEvents.length = 0;
  listen(["downloads"]);
  S().upsertDownload(download());
  S().upsertDownload(download({ id: "elsewhere", profile: "other", url: "https://files.example/b.zip" }));
  const [item] = await ask("downloads", "search", [{}]);
  assert.deepEqual([item.state, item.totalBytes, item.url], ["in_progress", 100, "https://files.example/a.zip"]);
  assert.equal((await ask("downloads", "search", [{ query: "b.zip" }])).length, 0, "another profile's downloads stay out of sight");
  S().upsertDownload(download({ state: "finished", received: 100 }));
  await tick();
  const changed = sentEvents.find((e) => e.event === "onChanged");
  assert.deepEqual(changed.args[0].state, { previous: "in_progress", current: "complete" });
  assert.equal(changed.args[0].id, item.id);
  const started = ask("downloads", "download", [{ url: "https://files.example/c.zip" }]);
  await tick(5);
  S().upsertDownload(download({ id: "wk-download-2", url: "https://files.example/c.zip", filename: "c.zip", path: "/tmp/c.zip" }));
  const newId = await started;
  assert.equal((await ask("downloads", "search", [{ id: newId }]))[0].url, "https://files.example/c.zip");
  assert.deepEqual(await ask("downloads", "erase", [{ id: item.id }]), [item.id]);
  await tick();
  assert.ok(sentEvents.some((e) => e.event === "onErased" && e.args[0] === item.id));
  await assert.rejects(ask("downloads", "pause", [item.id]), /Invalid download id/);
  listen([]);
});

test("history searches the profile's history the way Chrome does, last day by default, and reports new visits", async () => {
  windowWithTabs("https://home.example/");
  const now = Date.now();
  const entry = (url, title, lastVisit) => ({ url, title, favicon: null, visits: 1, lastVisit, visitTimes: [lastVisit] });
  const put = (list) => useBrowser.setState((s) => ({ history: { ...s.history, "": { list, floor: -Infinity, ready: true } } }));
  put([entry("https://news.example/", "News", now - 1000), entry("https://old.example/", "Old", now - 3 * 86_400_000)]);
  assert.deepEqual((await ask("history", "search", [{ text: "" }])).map((h) => h.url), ["https://news.example/"]);
  assert.deepEqual((await ask("history", "search", [{ text: "old", startTime: 0 }])).map((h) => h.title), ["Old"]);
  assert.equal((await ask("history", "getVisits", [{ url: "https://news.example/" }])).length, 1);
  sentEvents.length = 0;
  listen(["history"]);
  put([entry("https://fresh.example/", "Fresh", now), entry("https://news.example/", "News", now - 1000)]);
  await tick();
  assert.deepEqual(sentEvents.map((e) => [e.event, e.args[0].url ?? e.args[0].urls]), [
    ["onVisited", "https://fresh.example/"],
    ["onVisitRemoved", ["https://old.example/"]],
  ]);
  listen([]);
});

test("an unknown call is an error, not a hang, and native counts reach WebKit's telemetry", async () => {
  await assert.rejects(ask("history", "explode"), /isn't supported/);
  takeEngineSwitchCounts();
  for (const name of ["shimBookmarks", "shimBookmarks", "nativeHostLaunch", "privateExtensionLoaded", "somethingNew"]) emit("webKit.counted", { name });
  const counts = takeEngineSwitchCounts();
  assert.equal(counts.webkit_extension_bookmarks_calls, 2);
  assert.equal(counts.webkit_native_host_launches, 1);
  assert.equal(counts.webkit_private_extensions_loaded, 1);
});

test("a private window that opens before its profile synced asks for that profile's extensions", async () => {
  synced.length = 0;
  emit("webKit.extensionsWanted", { profile: "" });
  await tick(20);
  assert.deepEqual(synced, [""]);
});
