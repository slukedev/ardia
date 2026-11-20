import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { editDistance, search, snippetAround, splitByRanges } from "./searchMatch.ts";
import { findSetting, resolveSettingId, settingsIndexWith, SETTINGS, SETTINGS_INDEX } from "./settingsIndex.ts";

const ids = (query) => search(SETTINGS_INDEX, query).map((h) => h.entry.id);
const first = (query) => ids(query)[0];

const TOP = [
  ["cli", ["advanced.ardiaCommand", "advanced.programs"]],
  ["shell", ["advanced.ardiaCommand"]],
  ["devtools", ["advanced.ardiaCommand"]],
  ["remote debugging", ["advanced.ardiaCommand"]],
  ["command line", ["plugins.cli"]],
  ["terminal", ["advanced.ardiaCommand"]],
  ["ardia command", ["advanced.ardiaCommand"]],
  ["dark", ["appearance.theme"]],
  ["dark mode", ["appearance.theme"]],
  ["theme", ["appearance.theme"]],
  ["glass", ["appearance.glassTint", "appearance.interfaceStyle"]],
  ["liquid glass", ["appearance.interfaceStyle", "appearance.glassTint"]],
  ["tint", ["appearance.glassTint", "appearance.glassTint"]],
  ["default browser", ["general.defaultBrowser"]],
  ["search engine", ["profiles.searchEngine"]],
  ["webkit only", ["general.engineMode"]],
  ["chromium only", ["general.engineMode"]],
  ["ad block", ["general.blockAds"]],
  ["adblock", ["general.blockAds"]],
  ["block ads", ["general.blockAds"]],
  ["trackers", ["general.blockTrackers"]],
  ["cookies", ["general.blockCookieBanners"]],
  ["import", ["general.importBrowser", "profiles.importPasswords"]],
  ["import from chrome", ["general.importBrowser"]],
  ["profile", ["profiles.defaultProfile", "profiles.profiles"]],
  ["sidebar", ["tabs.sidebarSide"]],
  ["right sidebar", ["tabs.sidebarSide"]],
  ["vertical tabs", ["tabs.layout"]],
  ["pinned", ["profiles.shareTopApps", "tabs.balancedTopApps", "tabs.sleepingTabs"]],
  ["strikethrough", ["tabs.sleepingTabs"]],
  ["sleeping tabs", ["tabs.sleepingTabs"]],
  ["split", ["shortcuts.splitLinkModifier"]],
  ["split view", ["shortcuts.splitLinkModifier"]],
  ["peek", ["shortcuts.peekModifier", "tabs.peekLinksToOtherSites"]],
  ["pip", ["tabs.autoPictureInPicture"]],
  ["picture in picture", ["tabs.autoPictureInPicture"]],
  ["mini player", ["tabs.autoPictureInPicture"]],
  ["playing now", ["tabs.playingNowAcrossProfiles"]],
  ["now playing profiles", ["tabs.playingNowAcrossProfiles"]],
  ["downloads", ["general.downloadsFolder"]],
  ["download folder", ["general.downloadsFolder"]],
  ["shortcuts", ["shortcuts.menuCommands", "shortcuts.extensionShortcuts"]],
  ["keyboard shortcuts", ["shortcuts.menuCommands"]],
  ["hotkeys", ["shortcuts.menuCommands", "shortcuts.extensionShortcuts"]],
  ["⌘L", ["appearance.commandBarPlacement"]],
  ["alt tab", ["appearance.ctrlTab"]],
  ["ctrl tab", ["appearance.ctrlTab"]],
  ["control tab", ["appearance.ctrlTab"]],
  ["tab switcher", ["appearance.ctrlTab"]],
  ["switch tabs", ["appearance.ctrlTab"]],
  ["recent tabs", ["appearance.ctrlTab"]],
  ["address bar", ["appearance.addressBar"]],
  ["url bar", ["appearance.addressBar"]],
  ["command bar", ["appearance.commandBarPlacement"]],
  ["cmd l", ["appearance.commandBarPlacement"]],
  ["hide toolbar", ["tabs.hideToolbarWhileScrolling"]],
  ["auto hide toolbar", ["tabs.hideToolbarWhileScrolling"]],
  ["shrink", ["tabs.hideToolbarWhileScrolling"]],
  ["⌘z", ["shortcuts.undoReopensClosedTab"]],
  ["update", ["general.updateChannel", "general.autoUpdate"]],
  ["nightly", ["general.updateChannel"]],
  ["channel", ["general.updateChannel"]],
  ["sync", ["general.sync"]],
  ["extensions", ["profiles.extensions"]],
  ["font", ["advanced.chromeSettings"]],
  ["default zoom", ["advanced.chromeSettings"]],
  ["chrome settings", ["advanced.chromeSettings"]],
  ["preload", ["profiles.preloadPages"]],
  ["preload pages", ["profiles.preloadPages"]],
  ["prerender", ["profiles.preloadPages"]],
  ["preconnect", ["profiles.preloadPages"]],
  ["telemetry", ["general.crashDetails", "general.shareDiagnostics", "general.crashDetails"]],
  ["what's sent", ["general.crashDetails"]],
  ["whats sent", ["general.crashDetails"]],
  ["crash reports", ["general.shareDiagnostics"]],
  ["upscal", ["tabs.videoUpscaling"]],
  ["upscaling", ["tabs.videoUpscaling"]],
  ["unread", ["tabs.badges"]],
  ["notification", ["tabs.badges", "profiles.siteSettings"]],
  ["notifications", ["tabs.badges", "profiles.siteSettings"]],
  ["block notifications", ["profiles.siteSettings"]],
  ["notis", ["tabs.badges"]],
  ["badge", ["tabs.badges"]],
  ["bubble", ["tabs.badges"]],
  ["notification bubbles", ["tabs.badges"]],
  ["count", ["tabs.badges"]],
  ["dot", ["tabs.badges"]],
  ["location", ["profiles.siteSettings"]],
  ["camera", ["profiles.siteSettings"]],
  ["microphone", ["profiles.siteSettings"]],
  ["startup", ["general.openAtLogin"]],
  ["little arc", ["tabs.openLinksInLittleArdia"]],
  ["little ardia", ["tabs.openLinksInLittleArdia"]],
  ["little window", ["tabs.openLinksInLittleArdia"]],
  ["links from other apps", ["tabs.openLinksInLittleArdia", "tabs.appLinksFirst"]],
  ["slack", ["tabs.openLinksInLittleArdia"]],
  ["air traffic control", ["automations.linkRules"]],
  ["atc", ["automations.linkRules"]],
  ["open links in profile", ["automations.linkRules"]],
  ["onboarding", ["general.redoSetup"]],
  ["redo", ["general.redoSetup"]],
  ["welcome", ["general.redoSetup"]],
  ["setup", ["general.redoSetup", "general.setupCode"]],
  ["restore", ["general.windowsAndTabs"]],
  ["recently closed", ["general.windowsAndTabs"]],
  ["autohide", ["tabs.autoHideTabs"]],
  ["auto hide", ["tabs.autoHideTabs"]],
  ["borderless mode", ["appearance.pageFrame"]],
  ["minimal", ["appearance.minimalismMode"]],
  ["minimalism", ["appearance.minimalismMode"]],
  ["autoplay", ["profiles.siteSettings"]],
  ["1password", ["profiles.passwords"]],
  ["warn quitting", ["general.askBefore"]],
  ["trakers", ["general.blockTrackers"]],
  ["thme", ["appearance.theme"]],
  ["upscalling", ["tabs.videoUpscaling"]],
  ["extensoins", ["profiles.extensions", "profiles.webStore"]],
  ["safe browsing", ["advanced.webKitFraudWarnings"]],
  ["phishing", ["advanced.webKitFraudWarnings"]],
  ["unsaved", ["advanced.engineSwitchAsksAboutUnsavedWork"]],
  ["seamless", ["advanced.engineSwitchKeepsPage"]],
  ["drm prompt", ["advanced.offerWebKitForProtectedVideo"]],
  ["webkit limitations", ["advanced.enginesDiffer", "general.engineMode"]],
];

test("real queries put the setting people mean first", () => {
  const misses = TOP.filter(([q, want]) => !want.includes(first(q))).map(([q, want]) => `${q}: got ${first(q)}, want ${want.join(" or ")}`);
  assert.deepEqual(misses, []);
  assert.ok(TOP.length >= 40);
});

test("arc finds the Ctrl+Tab picker and the toolbar's address bar and command bar pickers", () => {
  const found = ids("arc");
  assert.ok(found.includes("appearance.ctrlTab"));
  assert.ok(found.some((id) => ["appearance.addressBar", "appearance.commandBarPlacement"].includes(id)));
});

test("whole-word hits rank above word prefixes, and a loose keyword no longer wins", () => {
  const found = ids("cli");
  assert.ok(["advanced.ardiaCommand", "advanced.programs"].includes(found[0]), found[0]);
  assert.ok(!found.includes("general.crashDetails"));
  const clickRows = found.filter((id) => /[Cc]lick/.test(SETTINGS.find((s) => s.id === id).title));
  assert.ok(clickRows.length && clickRows.every((id) => found.indexOf(id) > 0));
});

const placeOf = (id) => {
  const entry = SETTINGS.find((s) => s.id === id);
  return `${entry.pane} › ${entry.section}`;
};

const COLLAPSED = [
  ["telemetry", "general.crashDetails", ["general.shareDiagnostics"]],
  ["downloads", "general.downloadsFolder", ["general.askWhereToSave", "general.separateDownloadFolders"]],
];

test("results that land on the same place collapse into one", () => {
  for (const [query, kept, folded] of COLLAPSED) {
    const found = ids(query);
    assert.ok(found.includes(kept), `${query}: ${kept} is shown`);
    for (const id of folded) {
      assert.equal(placeOf(id), placeOf(kept), `${query}: ${id} lands where ${kept} does`);
      assert.ok(!found.includes(id), `${query}: ${id} folds into ${kept}`);
    }
  }
  for (const query of ["cli", "terminal", "dark", "telemetry", "downloads", "import", "tabs", "glass", "sidebar", "hotkeys", "notification"]) {
    const unnamed = search(SETTINGS_INDEX, query).filter((h) => !h.title.length && h.entry.paneTitle.toLowerCase() !== query);
    const places = unnamed.map((h) => placeOf(h.entry.id));
    assert.equal(new Set(places).size, places.length, `${query}: one result per place among rows matched without their title`);
  }
});

test("rows named by the query stay apart even when they share a place", () => {
  const tabs = search(SETTINGS_INDEX, "tabs").filter((h) => h.entry.section === "Layout" && h.title.length);
  assert.ok(tabs.length >= 2, "several Layout rows say tabs in their names");
  assert.equal(first("command line"), "plugins.cli");
  assert.equal(first("devtools"), "advanced.ardiaCommand");
});

test("a pane's name finds that pane's rows", () => {
  const found = search(SETTINGS_INDEX, "shortcuts");
  const sections = new Set(SETTINGS.filter((s) => s.pane === "shortcuts").map((s) => s.section));
  for (const section of sections) assert.ok(found.some((h) => h.entry.section === section), section);
  assert.equal(found[0].entry.pane, "shortcuts");
  assert.equal(search(SETTINGS_INDEX, "passwords")[0].entry.id, "profiles.passwords");
  assert.equal(search(SETTINGS_INDEX, "pasword")[0].entry.id, "profiles.passwords");
});

test("titles rank above keywords, keywords above descriptions", () => {
  const dark = search(SETTINGS_INDEX, "dark");
  assert.equal(dark[0].entry.id, "appearance.theme");
  assert.ok(dark.slice(1).every((h) => h.tier < dark[0].tier || h.score < dark[0].score));
  const sidebar = search(SETTINGS_INDEX, "sidebar");
  const firstNote = sidebar.findIndex((h) => h.note);
  assert.ok(firstNote > 0 && sidebar.findIndex((h) => h.entry.id === "tabs.sidebarSide") < firstNote);
});

test("every word of the query has to match", () => {
  assert.ok(!ids("block ads").includes("general.blockTrackers"));
  assert.ok(ids("the ardia command").includes("advanced.ardiaCommand"));
});

test("garbage finds nothing", () => {
  for (const q of ["zzzz", "qwxv", "xylophone", "asdfgh", "kubernetes"]) assert.deepEqual(ids(q), [], q);
});

test("short queries match word starts only", () => {
  assert.ok(ids("ta").length);
  assert.ok(!ids("ar").includes("general.blockTrackers"));
});

test("results come in one relevance order, not pane order", () => {
  const hits = search(SETTINGS_INDEX, "tabs");
  for (let i = 1; i < hits.length; i++) assert.ok(hits[i - 1].tier >= hits[i].tier, `${hits[i - 1].entry.id} before ${hits[i].entry.id}`);
  const cli = search(SETTINGS_INDEX, "cli").map((h) => h.entry.pane);
  assert.equal(cli[0], "advanced");
});

test("matches carry ranges to highlight, in the text shown", () => {
  const [hit] = search(SETTINGS_INDEX, "ask before");
  assert.deepEqual(splitByRanges(hit.entry.title, hit.title), [{ text: "Ask", highlighted: true }, { text: " ", highlighted: false }, { text: "before", highlighted: true }]);
  const cli = search(SETTINGS_INDEX, "cli").find((h) => h.entry.id === "shortcuts.cmdClickCreatesTabGroup");
  assert.deepEqual(splitByRanges(cli.entry.title, cli.title).filter((p) => p.highlighted).map((p) => p.text), ["cli"]);
  const term = search(SETTINGS_INDEX, "terminal")[0];
  assert.deepEqual(term.title, []);
  assert.equal(term.note.text, "terminal");
  const pip = search(SETTINGS_INDEX, "picture in picture")[0];
  assert.ok(pip.title.length >= 1);
  const line = search(SETTINGS_INDEX, "command line")[0];
  assert.ok(line.title.length >= 1);
});

test("a long matching text shows the part around its match", () => {
  const text = "Right-click empty space in the sidebar and choose New Live Folder to add one.";
  const at = text.indexOf("Live");
  const cut = snippetAround(text, [{ start: at, end: at + 4 }], 30);
  assert.ok(cut.text.startsWith("…"));
  assert.equal(cut.text.slice(cut.ranges[0].start, cut.ranges[0].end), "Live");
});

test("the official plugins turn up by their pinned title and their manifest's keywords, and the old anchor still leads there", () => {
  for (const query of ["command line", "plugins", "official plugins"]) assert.ok(ids(query).includes("plugins.cli") || ids(query).includes("plugins.official"), query);
  assert.ok(ids("command line").includes("plugins.cli"));
  assert.ok(ids("terminal").includes("plugins.cli"), "its pinned blurb says terminal");
  assert.ok(!search(SETTINGS_INDEX, "skills").some((h) => h.entry.id === "plugins.cli"), "no keyword of the plugin's own is baked into the browser");
  const withKeywords = settingsIndexWith({ "plugins.cli": ["skills", "cli"] });
  assert.ok(search(withKeywords, "skills").some((h) => h.entry.id === "plugins.cli"), "the manifest's keywords find it");
  assert.equal(withKeywords.length, SETTINGS_INDEX.length);
  assert.ok(ids("plugins").includes("plugins.official"));
  assert.equal(first("official plugins"), "plugins.official");
  assert.equal(resolveSettingId("plugins.commandLine"), "plugins.cli");
  assert.equal(findSetting("plugins.commandLine")?.id, "plugins.cli");
});

test("edit distance counts a swap as one edit", () => {
  assert.equal(editDistance("tabs", "tbas", 2), 1);
  assert.equal(editDistance("kitten", "sitting", 3), 3);
  assert.equal(editDistance("abc", "abcdefg", 2), 3);
});

test("every indexed setting is anchored in its pane, and every anchor is indexed", () => {
  const dir = new URL("./panes/", import.meta.url);
  const sources = readdirSync(dir)
    .filter((f) => f.endsWith(".tsx"))
    .map((f) => readFileSync(new URL(f, dir), "utf8"))
    .join("\n");
  const panes = new Set(SETTINGS.map((s) => s.pane));
  const anchors = new Set([
    ...[...sources.matchAll(/["`]([a-zA-Z]+)\.([a-zA-Z]+)["`]/g)].filter((m) => panes.has(m[1])).map((m) => `${m[1]}.${m[2]}`),
    ...(sources.includes("anchor={`automations.${id}`}") ? ["github", "bitbucket", "notion", "confluence", "gdrive"].map((id) => `automations.${id}`) : []),
  ]);
  if (sources.includes("officialPluginAnchor(plugin.name)")) for (const s of SETTINGS) if (s.pane === "plugins" && s.section === "Official" && s.id !== "plugins.official") anchors.add(s.id);
  const indexed = new Set(SETTINGS.map((s) => s.id));
  for (const id of indexed) assert.ok(anchors.has(id), `${id} is in the index but no pane anchors it`);
  for (const id of anchors) assert.ok(indexed.has(id), `${id} is anchored in a pane but not in the index`);
});

test("every settings row with a fixed title is searchable", () => {
  const dir = new URL("./panes/", import.meta.url);
  const notSettings = /Sheet$|Connect$|Details|List$|Page$|^ThisProfileSection$/;
  const statusRows = new Set(["iCloud Drive is off on this Mac", "uBlock Origin isn't answering", "Delete profile", "Apply a setup code", "Passkeys"]);
  for (const file of readdirSync(dir).filter((f) => f.endsWith(".tsx"))) {
    const source = readFileSync(new URL(file, dir), "utf8");
    for (const m of source.matchAll(/<Row\b([^>]*?)title="([^"]+)"/gs)) {
      const owner = [...source.slice(0, m.index).matchAll(/^(?:export )?function (\w+)/gm)].at(-1)?.[1] ?? "";
      if (notSettings.test(owner) || /^(No |Just |\s*$)/.test(m[2]) || statusRows.has(m[2])) continue;
      assert.ok(/anchor=/.test(m[1]), `${file}: <Row title="${m[2]}"> in ${owner} has no anchor, so search can't find it`);
    }
  }
});

test("a row its pane doesn't draw is left out of search, by the same rule the pane hides it with", async () => {
  const { unshownSettings } = await import("./settingsIndex.ts");
  const { DEFAULT_SETTINGS } = await import("../../state/settings/settings.ts");
  const unshown = (settings, env) => new Set(unshownSettings({ ...DEFAULT_SETTINGS, ...settings }, env).split("\n").filter(Boolean));
  const across = unshown({}, { top: true });
  assert.ok(!across.has("tabs.buttons"), "the Hide Tabs button shows in both layouts");
  for (const id of ["tabs.sidebarSide", "appearance.sidebarTextSize", "appearance.addressBar"]) assert.ok(across.has(id), id);
  const sidebar = unshown({}, { top: false, glass: true, syncOn: true, calendarAccess: true });
  for (const id of ["tabs.sidebarSide", "appearance.sidebarTextSize", "general.syncFolder", "automations.meetingAlert"]) assert.ok(!sidebar.has(id), id);
  for (const id of ["appearance.interfaceStyle", "appearance.glassTint"]) assert.ok(unshown({}, { top: false }).has(id), id);
  assert.ok(unshown({ interfaceStyle: "classic" }, { top: false, glass: true }).has("appearance.glassTint"));
  assert.ok(unshown({ memorySaver: false }, { top: false }).has("advanced.keepActiveSites"));
  assert.ok(!unshown({ memorySaver: true }, { top: false }).has("advanced.keepActiveSites"));
  assert.ok(unshown({ newTabOpens: "commandBar" }, { top: false }).has("tabs.newTabUrl"));
  assert.ok(unshown({ cleanUpInactiveTabsAfterMinutes: 60 }, { top: false }).has("tabs.suggestCleanUp"));
  assert.ok(unshown({ separateDownloadFolders: true }, { top: false }).has("general.downloadsFolder"));
  assert.ok(unshown({}, { top: false }).has("profiles.profileDownloadsFolder"));
  assert.ok(unshown({ addressBar: "sidebar" }, { top: false }).has("appearance.compactToolbar"));
  assert.ok(!unshown({ addressBar: "sidebar" }, { top: true }).has("appearance.compactToolbar"));
  const chromiumOnly = unshown({ engineMode: "chromium" }, { top: false });
  for (const id of ["advanced.pageEngine", "advanced.websiteEngines", "advanced.enginesDiffer", "advanced.offerWebKitForProtectedVideo", "advanced.webKitFraudWarnings"]) assert.ok(chromiumOnly.has(id), id);
  for (const id of ["general.engineMode", "advanced.engineSwitchKeepsPage", "advanced.engineSwitchAsksAboutUnsavedWork"]) assert.ok(!chromiumOnly.has(id), id);
  const webkitOnly = unshown({ engineMode: "webkit" }, { top: false });
  for (const id of ["advanced.pageEngine", "advanced.websiteEngines", "advanced.offerWebKitForProtectedVideo"]) assert.ok(webkitOnly.has(id), id);
  for (const id of ["general.engineMode", "advanced.enginesDiffer", "advanced.webKitFraudWarnings"]) assert.ok(!webkitOnly.has(id), id);
});

const SHOWN_BY_LOADED_DATA = ["UpdatesSection.tsx: general.autoUpdate", "UpdatesSection.tsx: general.updateChannel"];

test("panes leave showing and hiding an anchored row to the row's own rule", () => {
  const dir = new URL("./panes/", import.meta.url);
  const wrapped = readdirSync(dir).flatMap((file) =>
    [...readFileSync(new URL(file, dir), "utf8").matchAll(/\{[^{}\n]*&&\s*(?:\(\s*)?(?:<Row anchor="([\w.]+)"|toggle\("\w+", "([\w.]+)"\))/g)].map((m) => `${file}: ${m[1] ?? m[2]}`),
  );
  assert.deepEqual(wrapped, SHOWN_BY_LOADED_DATA);
});

test("a one-letter query matches setting names, not sections or pane names", () => {
  const titleWords = (id) => SETTINGS_INDEX.find((p) => p.entry.id === id).entry.title.toLowerCase().split(/[^a-z0-9]+/);
  for (const q of ["c", "t", "p"]) {
    const found = ids(q);
    assert.ok(found.length, q);
    for (const id of found) {
      const entry = SETTINGS_INDEX.find((p) => p.entry.id === id).entry;
      assert.ok(titleWords(id).some((w) => w.startsWith(q)) || (entry.keywords ?? []).some((k) => k.toLowerCase().split(/[^a-z0-9]+/).some((w) => w.startsWith(q))), `${q}: ${id}`);
    }
  }
});

test("arrowing through results scrolls only as far as the selected row needs", async () => {
  const { scrollToShow, RESULTS_TOP, RESULTS_BOTTOM } = await import("./searchResultLayout.ts");
  assert.equal(scrollToShow(300, 40, 0, 400, false), 0);
  assert.equal(scrollToShow(500, 40, 0, 400, false), 140 + RESULTS_BOTTOM);
  assert.equal(scrollToShow(500, 70, 0, 400, false), 170 + RESULTS_BOTTOM);
  assert.equal(scrollToShow(100, 40, 200, 400, false), 100 - RESULTS_TOP);
  assert.equal(scrollToShow(260, 40, 200, 400, false), 200);
  assert.equal(scrollToShow(260, 40, 200, 400, true), 0);
});

test("Interface size turns up for every word people use for UI scaling", () => {
  for (const query of ["scale", "scaling", "zoom", "UI size", "interface size", "fractional scaling", "1440p", "bigger", "smaller", "display"]) assert.ok(ids(query).includes("appearance.interfaceScale"), query);
  for (const query of ["interface size", "ui size", "scaling", "fractional scaling", "1440p", "ui scale"]) assert.equal(first(query), "appearance.interfaceScale", query);
});

test("the profile switcher toggle turns up for the words of the old three-way row", () => {
  for (const query of ["profile switcher", "profile dots", "profile icons", "dots", "space icons", "switcher in the sidebar shows"]) assert.ok(ids(query).includes("profiles.showProfileDots"), query);
  for (const query of ["profile switcher", "profile dots"]) assert.equal(first(query), "profiles.showProfileDots", query);
  assert.equal(findSetting("profiles.switcherShows"), undefined);
});

test("Minimalism mode turns up for every word people use for it", () => {
  for (const query of ["minimal", "minimalism", "clean", "zen", "distraction free", "no toolbar"]) assert.ok(ids(query).includes("appearance.minimalismMode"), query);
});

test("autoplay and notification blocking are found through each profile's Site settings", () => {
  for (const query of ["block autoplay on every site", "block requests to send notifications", "camera", "autoplay"]) assert.equal(first(query), "profiles.siteSettings", query);
});

test("search leaves out the official plugins when Settings › Plugins doesn't draw them, as on a build without the bundled command line", async () => {
  const { unshownSettings } = await import("./settingsIndex.ts");
  const { DEFAULT_SETTINGS } = await import("../../state/settings/settings.ts");
  const unshown = (env) => new Set(unshownSettings(DEFAULT_SETTINGS, env).split("\n").filter(Boolean));
  const without = unshown({ top: false, officialPlugins: [] });
  assert.ok(without.has("plugins.cli"));
  assert.ok(without.has("plugins.official"));
  const onlyAi = unshown({ top: false, officialPlugins: ["ai"] });
  assert.ok(onlyAi.has("plugins.cli"));
  assert.ok(!onlyAi.has("plugins.official"));
  const bundled = unshown({ top: false, officialPlugins: ["cli"] });
  assert.ok(!bundled.has("plugins.cli"));
  assert.ok(!bundled.has("plugins.official"));
});
