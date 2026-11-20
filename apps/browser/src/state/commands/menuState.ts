import type { MenuBookmark, MenuState } from "../../platform/commands";
import { engineBookmarkRoots, folderChildren, isBookmarked, isWithin, ROOT_TITLES } from "../bookmarks/bookmarks";
import type { BrowserState } from "../browser/store";
import { changedIds } from "../browser/changes";
import { activeTab, bookmarkProfileId, engineProfile, IDLE_LIVE, isPinnedRow, tabLabel, togglePinTitle, windowTitle, tabLayoutOf, tabsShownIn } from "../browser/model";
import { switchableEngine, tabEngine } from "../engines/engines";
import { readerState as readerFor, type ReaderState } from "../reader/reader";
import { peekTabId } from "../peek/peek";
import { canHideElements } from "../site/hiddenElements";
import { splitOf } from "../splits/splits";
import { canGoBack, canGoForward } from "../tabs/navigation";
import { liveReachOf, shownLiveOf } from "../tabs/tabLive";
import type { Bookmarks, BookmarkNode, Tab } from "../browser/types";
import { isInternalTab } from "../pages/urls";
import { muteState, muteTitle } from "../tabs/mute";
import { sidebarMenuState } from "../sidebar/commands";
import { LITTLE_ARDIA_DISABLED_COMMANDS, PAGE_COMMANDS, PAGE_COMMANDS_OFF_INTERNAL_PAGES, settingChecks, UNAVAILABLE_COMMANDS, WINDOW_COMMANDS } from "../commands/commandCatalog";
import { extensionMenu } from "../extensions/actions";
import type { InstalledExtension } from "../extensions/store";
import { menuBarBindings, menuBarMouseBindings } from "./commandShortcuts";
import { focusedWindowOf } from "../windows/ui";
import { clearableRecentlyClosed, closedWindowTitle, newestClosed, recentlyClosedIn } from "../windows/recentlyClosedList";
import { BOOKMARK_COMMANDS, bookmarksShown } from "../bookmarks/visibility";
import { PLATFORM_FEATURES } from "../../lib/platformFeatures";

function menuBookmarks(b: Bookmarks, folderId: string, depth = 0): MenuBookmark[] {
  return folderChildren(b, folderId).map((n: BookmarkNode) =>
    n.kind === "url"
      ? { id: n.id, title: n.title || n.url, url: n.url }
      : { id: n.id, title: n.title, children: depth < 6 ? menuBookmarks(b, n.id, depth + 1) : [] },
  );
}

type BookmarkMenus = Pick<MenuState, "bookmarkFolders" | "recentBookmarks" | "bookmarksBar" | "otherBookmarks">;
const bookmarkMenuCache = new WeakMap<Bookmarks, Map<string, BookmarkMenus>>();

function bookmarkMenus(b: Bookmarks, engine: string): BookmarkMenus {
  let perEngine = bookmarkMenuCache.get(b);
  if (!perEngine) bookmarkMenuCache.set(b, (perEngine = new Map()));
  const cached = perEngine.get(engine);
  if (cached) return cached;
  const roots = engineBookmarkRoots(b, engine);
  const menus: BookmarkMenus = roots
    ? {
        bookmarkFolders: [
          { id: roots.bar, title: ROOT_TITLES.bar },
          { id: roots.other, title: ROOT_TITLES.other },
          ...[...folderChildren(b, roots.bar), ...folderChildren(b, roots.other)]
            .filter((n) => n.kind === "folder")
            .map((n) => ({ id: n.id, title: n.title })),
        ],
        recentBookmarks: Object.values(b.nodes)
          .filter((n): n is Extract<BookmarkNode, { kind: "url" }> => n.kind === "url" && isWithin(b, n.id, [roots.bar, roots.other]))
          .sort((x, y) => y.addedAt - x.addedAt)
          .slice(0, 5)
          .map((n) => ({ id: n.id, title: n.title || n.url, url: n.url })),
        bookmarksBar: menuBookmarks(b, roots.bar),
        otherBookmarks: menuBookmarks(b, roots.other) }
    : { bookmarkFolders: [], recentBookmarks: [], bookmarksBar: [], otherBookmarks: [] };
  perEngine.set(engine, menus);
  return menus;
}

export function menuState(s: BrowserState, liveOfTab = (id: string) => shownLiveOf(s, id)): MenuState {
  const focused = focusedWindowOf(s);
  const windowId = focused && s.windows[focused] ? focused : undefined;
  const w = windowId ? s.windows[windowId] : undefined;
  const tab = windowId ? activeTab(s, windowId) : undefined;
  const peek = windowId ? peekTabId(s, windowId) : undefined;
  const page = peek ? s.tabs[peek] : tab;
  const live = page ? liveOfTab(page.id) : IDLE_LIVE;
  const bookmarkProfile = bookmarkProfileId(s, w);
  const regularWindows = s.windowOrder.filter((id) => s.windows[id]!.kind !== "private" && s.windows[id]!.kind !== "small");

  const disabled: string[] = [];
  if (!tab || !splitOf(s, tab.id)) disabled.push("focusNextPane", "focusPreviousPane");
  if (w && tabLayoutOf(s, w.id) === "top") disabled.push("toggleAddressBar", "toggleSidebarSide");
  if (s.settings.minimalismMode) disabled.push("toggleAddressBar");
  if (!w) disabled.push(...WINDOW_COMMANDS);
  else {
    if (!page?.url) disabled.push(...PAGE_COMMANDS);
    else if (isInternalTab(page)) disabled.push(...PAGE_COMMANDS_OFF_INTERNAL_PAGES);
    if (!page || !canGoBack(page.id, live)) disabled.push("back");
    if (!page || !canGoForward(page.id, live)) disabled.push("forward");
    if (!live.isLoading) disabled.push("stop");
    if (w.kind === "private") disabled.push("moveTabToProfile", "moveTabToWindow", "switchProfile", "nextProfile", "previousProfile");
    else if (tab) disabled.push(`moveTabToProfile:${tab.profileId}`);
    if (regularWindows.length < 2) disabled.push("mergeAllWindows");
  }
  const showBookmarks = bookmarksShown(s.settings);
  if (!showBookmarks) disabled.push(...BOOKMARK_COMMANDS);
  if (!s.closedTabs.length && !s.closedWindows.length && !s.closedGroups.length) disabled.push("reopenClosedTab");
  if (!s.closedWindows.length) disabled.push("reopenClosedWindow");

  const checked = settingChecks(s.settings);
  if (s.settings.addressBar === "sidebar") checked.push("toggleAddressBar");
  if (s.settings.sidebarSide === "right") checked.push("toggleSidebarSide");
  if (tabLayoutOf(s, windowId) === "sidebar") checked.push("toggleTabLayout");
  if (w && !tabsShownIn(s, w.id)) checked.push("toggleSidebar");

  const titles: Record<string, string> = {};
  if (tab?.pin) titles.togglePin = togglePinTitle(tab);
  if (isPinnedRow(tab)) titles["togglePin:tile"] = "Move to Top Apps";
  else disabled.push("togglePin:tile");
  if (page) titles.toggleMute = muteTitle(muteState(s, page));
  if (page && tabEngine(s, page.id) === "webkit") titles.togglePageEngine = "Open Page in Chromium";
  if (!switchableEngine(s, page?.url)) disabled.push("togglePageEngine");
  const reader = page ? readerFor(page.id) : undefined;
  if (reader?.active) titles.toggleReader = "Hide Reader";
  if (!reader?.active && !reader?.available) disabled.push("toggleReader");
  if (page?.url && isBookmarked(s, bookmarkProfile, page.url)) {
    titles.bookmarkPage = "Edit Bookmark…";
  }

  if (!s.settings.openLinksInLittleArdia) titles.toggleOpenLinksInLittleArdia = "Open Links from Other Apps in Little Ardia";
  if (!page || !canHideElements(s, page.id)) disabled.push("hideElement", "showHiddenElements");

  const sidebar = sidebarMenuState(s, windowId);
  disabled.push(...sidebar.disabled, ...UNAVAILABLE_COMMANDS);
  Object.assign(titles, sidebar.titles);
  if (peek) {
    titles.openFile = "Open Peek as Tab";
    titles.closeTab = "Close Peek";
  }
  if (w?.kind === "small") {
    disabled.push(...LITTLE_ARDIA_DISABLED_COMMANDS);
    titles.openFile = "Open in Ardia";
  }

  const closed = newestClosed(recentlyClosedIn(s, w)).map((c) => ({ id: c.id, title: c.kind === "tab" ? c.tab.title || tabLabel(c.tab) : closedWindowTitle(c) }));

  if (!clearableRecentlyClosed(s, windowId)) disabled.push("clearRecentlyClosed");
  return {
    checked,
    disabled,
    titles,
    profiles: s.profileOrder.map((id) => ({ id, title: s.profiles[id]!.name, current: w?.profileId === id })),
    windows: w?.kind === "private" ? [] : regularWindows.filter((id) => id !== windowId).map((id) => ({ id, title: windowTitle(s, id) })),
    ...bookmarkMenus(s.bookmarks, engineProfile(s, bookmarkProfile)),
    bookmarksShown: showBookmarks,
    recentlyClosed: closed,
    recentlyClosedGroups: sidebar.recentlyClosedGroups,
    warnBeforeQuitting: s.settings.warnBeforeQuitting,
    warnBeforeClosingWindow: s.settings.warnBeforeClosingWindow,
    undoReopensClosedTab: s.settings.undoReopensClosedTab,
    linksOpenInLittleArdia: s.settings.openLinksInLittleArdia,
    littleArdiaShortcutFromAnyApp: PLATFORM_FEATURES.littleArdiaShortcutFromAnyApp && s.settings.littleArdiaShortcutFromAnyApp,
    downloadsInProgress: s.downloads.filter((d) => d.state === "downloading").length,
    shortcuts: menuBarBindings(s),
    mouseShortcuts: menuBarMouseBindings(s),
    extensions: extensionMenu(s, windowId) };
}

export type MenuReads = ReadonlySet<keyof BrowserState>;

export function trackedMenuState(s: BrowserState): { state: MenuState; reads: MenuReads } {
  const reads = new Set<keyof BrowserState>();
  const tracked = new Proxy(s, {
    get(target, key, receiver) {
      if (typeof key === "string") reads.add(key as keyof BrowserState);
      return Reflect.get(target, key, receiver);
    },
  });
  return { state: menuState(tracked), reads };
}

export const HIDDEN_TAB_FIELDS_IN_MENU = ["id", "windowId", "profileId", "pin"] as const satisfies readonly (keyof Tab)[];

function shownOrSelected(s: BrowserState, tab: Tab): boolean {
  const w = s.windows[tab.windowId];
  if (!w) return true;
  for (const profile in w.activeTabIds) if (w.activeTabIds[profile] === tab.id) return true;
  return peekTabId(s, tab.windowId) === tab.id || !!s.selection[tab.windowId]?.includes(tab.id);
}

function tabsChangedForMenu(s: BrowserState, prev: BrowserState): boolean {
  for (const id of changedIds(s.tabs, prev.tabs)) {
    const now = s.tabs[id];
    const was = prev.tabs[id];
    if (!now || !was || shownOrSelected(s, now)) return true;
    for (const field of HIDDEN_TAB_FIELDS_IN_MENU) if (now[field] !== was[field]) return true;
  }
  return false;
}

export const liveReachesMenu = (s: BrowserState, tabId: string): boolean =>
  liveReachOf(s, tabId).some((id) => {
    const tab = s.tabs[id];
    return !!tab && shownOrSelected(s, tab);
  });

const readerShownInMenu = (reader: ReaderState | undefined) => (reader?.active ? 2 : 0) + (reader?.available ? 1 : 0);

export function readerChangesMenu(next: Record<string, ReaderState | undefined>, prev: Record<string, ReaderState | undefined>): boolean {
  for (const id in next) if (readerShownInMenu(next[id]) !== readerShownInMenu(prev[id])) return true;
  for (const id in prev) if (!(id in next) && readerShownInMenu(prev[id]) !== 0) return true;
  return false;
}

const extensionInMenu = (x: InstalledExtension) => [x.id, x.name, x.actionIcon || x.icon, x.enabled, x.incognito].join("\u0000");
const extensionsInMenu = (list: readonly InstalledExtension[] | undefined) => (list ?? []).map(extensionInMenu).join("\u0001");

export function extensionsChangeMenu(next: Record<string, InstalledExtension[]>, prev: Record<string, InstalledExtension[]>): boolean {
  for (const profile of new Set([...Object.keys(next), ...Object.keys(prev)])) {
    if (next[profile] !== prev[profile] && extensionsInMenu(next[profile]) !== extensionsInMenu(prev[profile])) return true;
  }
  return false;
}

export function menuInputsChanged(reads: MenuReads, s: BrowserState, prev: BrowserState): boolean {
  for (const key of reads) {
    if (s[key] === prev[key]) continue;
    if (key !== "tabs" || tabsChangedForMenu(s, prev)) return true;
  }
  return false;
}
