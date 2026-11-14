import { addHistoryVisits, deleteHistoryUrls } from "../../platform/history";
import { cancelDownload, getDownloadSettings, keepDownload, pauseDownload, resumeDownload, type Download } from "../../platform/downloads";
import { moveToTrash, openFile, revealFile } from "../../platform/files";
import { clearBrowsingData } from "../../platform/profiles";
import type { WebKitExtensionCall } from "../../platform/webkit";
import { storeAction, useBrowser, type BrowserState } from "../browser/store";
import { historyOf } from "../history/history";
import {
  appProfileOf,
  bookmarkIds,
  bookmarkOwnedBy,
  bookmarkTreeRoot,
  chromeBookmark,
  chromeDownload,
  chromeGroupIdOf,
  chromeHistoryItem,
  chromeTabGroup,
  downloadsFor,
  groupsFor,
  isChromeColor,
  keyFor,
  numberFor,
  tabOfRef,
  windowOfRef,
  type BookmarkIds,
  type ChromeBookmark,
  type ChromeDownload,
} from "./webKitExtensionData";

export class ExtensionApiError extends Error {}

const fail = (message: string): never => {
  throw new ExtensionApiError(message);
};

type Handler = (call: WebKitExtensionCall, s: BrowserState) => unknown;
type Options = Record<string, unknown>;

const store = () => useBrowser.getState();
const optionsOf = (value: unknown): Options => (value && typeof value === "object" && !Array.isArray(value) ? (value as Options) : {});
const textOf = (value: unknown) => (typeof value === "string" ? value : "");
const DAY_MS = 86_400_000;
const DOWNLOAD_START_MS = 10_000;

const addBookmark = storeAction("addBookmark");
const addBookmarkFolder = storeAction("addBookmarkFolder");
const updateBookmark = storeAction("updateBookmark");
const moveBookmark = storeAction("moveBookmark");
const removeBookmark = storeAction("removeBookmark");
const updateGroup = storeAction("updateGroup");
const addTabsToGroup = storeAction("addTabsToGroup");
const removeTabsFromGroup = storeAction("removeTabsFromGroup");
const groupTabs = storeAction("groupTabs");
const removeDownload = storeAction("removeDownload");

function downloadOf(call: WebKitExtensionCall, s: BrowserState, id: unknown): Download {
  const key = keyFor("download", id);
  const found = key ? downloadsFor(s, call.profile, call.base, call.private).find((d) => d.id === key) : undefined;
  return found ?? fail(`Invalid download id ${String(id)}`);
}

const matches = (pattern: unknown, value: string) => {
  if (typeof pattern !== "string") return true;
  try {
    return new RegExp(pattern).test(value);
  } catch {
    return false;
  }
};

export function searchDownloads(items: ChromeDownload[], query: Options): ChromeDownload[] {
  const terms = textOf(query.query) ? textOf(query.query).split(/\s+/).filter(Boolean) : Array.isArray(query.query) ? query.query.map(textOf) : [];
  const found = items.filter((d) => {
    if (typeof query.id === "number" && d.id !== query.id) return false;
    if (typeof query.url === "string" && d.url !== query.url && d.finalUrl !== query.url) return false;
    if (typeof query.filename === "string" && d.filename !== query.filename) return false;
    if (typeof query.state === "string" && d.state !== query.state) return false;
    if (typeof query.paused === "boolean" && d.paused !== query.paused) return false;
    if (typeof query.exists === "boolean" && d.exists !== query.exists) return false;
    if (typeof query.mime === "string" && d.mime !== query.mime) return false;
    if (typeof query.danger === "string" && d.danger !== query.danger) return false;
    if (!matches(query.urlRegex, d.url) || !matches(query.filenameRegex, d.filename)) return false;
    const haystack = `${d.url} ${d.filename}`.toLowerCase();
    return terms.every((t) => (t.startsWith("-") ? !haystack.includes(t.slice(1).toLowerCase()) : haystack.includes(t.toLowerCase())));
  });
  const order = Array.isArray(query.orderBy) ? query.orderBy.map(textOf) : [];
  for (const field of [...order].reverse()) {
    const name = field.replace(/^-/, "") as keyof ChromeDownload;
    const sign = field.startsWith("-") ? -1 : 1;
    found.sort((a, b) => {
      const x = a[name] ?? "";
      const y = b[name] ?? "";
      return x < y ? -sign : x > y ? sign : 0;
    });
  }
  const limit = typeof query.limit === "number" ? query.limit : 1000;
  return limit > 0 ? found.slice(0, limit) : found;
}

function waitForDownload(url: string, before: ReadonlySet<string>): Promise<number> {
  const pick = (s: BrowserState) => s.downloads.find((d) => d.url === url && !before.has(d.id));
  const now = pick(store());
  if (now) return Promise.resolve(numberFor("download", now.id));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      stop();
      reject(new ExtensionApiError("The download didn't start."));
    }, DOWNLOAD_START_MS);
    const stop = useBrowser.subscribe((s) => {
      const found = pick(s);
      if (!found) return;
      clearTimeout(timer);
      stop();
      resolve(numberFor("download", found.id));
    });
  });
}

const downloadsSeen = (s: BrowserState) => new Set(s.downloads.map((d) => d.id));

const downloads: Record<string, Handler> = {
  download: (call, s) => waitForDownload(textOf(optionsOf(call.args[0]).url), downloadsSeen(s)),
  search: (call, s) => searchDownloads(downloadsFor(s, call.profile, call.base, call.private).map((d) => chromeDownload(d)), optionsOf(call.args[0])),
  pause: async (call, s) => void (await pauseDownload(downloadOf(call, s, call.args[0]).id)),
  resume: async (call, s) => void (await resumeDownload(downloadOf(call, s, call.args[0]).id)),
  cancel: async (call, s) => void (await cancelDownload(downloadOf(call, s, call.args[0]).id)),
  acceptDanger: async (call, s) => void (await keepDownload(downloadOf(call, s, call.args[0]).id)),
  erase: (call, s) => {
    const list = downloadsFor(s, call.profile, call.base, call.private);
    const erased = searchDownloads(list.map((d) => chromeDownload(d)), optionsOf(call.args[0]));
    for (const d of erased) {
      const key = keyFor("download", d.id);
      if (key) removeDownload(key);
    }
    return erased.map((d) => d.id);
  },
  open: async (call, s) => void (await openFile(downloadOf(call, s, call.args[0]).path)),
  show: async (call, s) => void (await revealFile(downloadOf(call, s, call.args[0]).path)),
  showDefaultFolder: async (call) => {
    const { folder } = await getDownloadSettings(call.base);
    if (folder) await openFile(folder);
  },
  removeFile: async (call, s) => {
    const d = downloadOf(call, s, call.args[0]);
    if (d.state !== "finished") fail("Download must be complete");
    await moveToTrash(d.path);
  },
  getFileIcon: () => fail("Not supported"),
  setUiOptions: () => undefined,
  setShelfEnabled: () => undefined,
};

function historyRange(options: Options, now: number) {
  const start = typeof options.startTime === "number" ? options.startTime : now - DAY_MS;
  const end = typeof options.endTime === "number" ? options.endTime : Infinity;
  return { start, end };
}

const history: Record<string, Handler> = {
  search: (call, s) => {
    const options = optionsOf(call.args[0]);
    const { start, end } = historyRange(options, Date.now());
    const text = textOf(options.text).toLowerCase();
    const max = typeof options.maxResults === "number" ? options.maxResults : 100;
    const found = historyOf(s, appProfileOf(s, call.base) ?? "")
      .filter((h) => h.lastVisit >= start && h.lastVisit < end && (!text || h.url.toLowerCase().includes(text) || h.title.toLowerCase().includes(text)))
      .sort((a, b) => b.lastVisit - a.lastVisit);
    return (max > 0 ? found.slice(0, max) : found).map(chromeHistoryItem);
  },
  getVisits: (call, s) => {
    const url = textOf(optionsOf(call.args[0]).url);
    const entry = historyOf(s, appProfileOf(s, call.base) ?? "").find((h) => h.url === url);
    if (!entry) return [];
    const id = String(numberFor("history", url));
    return (entry.visitTimes?.length ? entry.visitTimes : [entry.lastVisit]).map((visitTime, i) => ({
      id,
      visitId: `${id}.${i}`,
      visitTime,
      referringVisitId: "0",
      transition: "link",
      isLocal: true,
    }));
  },
  addUrl: async (call) => {
    const options = optionsOf(call.args[0]);
    const url = textOf(options.url);
    if (!/^(https?|file|ftp):/i.test(url)) fail("Invalid URL.");
    await addHistoryVisits(call.base, [{ url, title: textOf(options.title), visitTimes: [Date.now()] }]);
  },
  deleteUrl: async (call) => void (await deleteHistoryUrls(call.base, [textOf(optionsOf(call.args[0]).url)].filter(Boolean))),
  deleteRange: async (call, s) => {
    const options = optionsOf(call.args[0]);
    const now = Date.now();
    const { start, end } = historyRange(options, now);
    if (end >= now) return void (await clearBrowsingData(call.base, ["history"], start));
    const urls = historyOf(s, appProfileOf(s, call.base) ?? "").filter((h) => h.lastVisit >= start && h.lastVisit < end).map((h) => h.url);
    await deleteHistoryUrls(call.base, urls);
  },
  deleteAll: async (call) => void (await clearBrowsingData(call.base, ["history"])),
};

function bookmarkTarget(s: BrowserState, ids: BookmarkIds, id: unknown): string {
  const key = ids.fromChrome(id);
  if (!key || !s.bookmarks.nodes[key] || !bookmarkOwnedBy(s, ids, key)) fail("Can't find bookmark for id.");
  return key!;
}

const isRootId = (ids: BookmarkIds, key: string) => key === ids.roots.bar || key === ids.roots.other;

function bookmarkSearch(s: BrowserState, ids: BookmarkIds, query: unknown): ChromeBookmark[] {
  const options = typeof query === "string" ? { query } : optionsOf(query);
  const words = textOf(options.query).toLowerCase().split(/\s+/).filter(Boolean);
  const url = typeof options.url === "string" ? options.url : null;
  const title = typeof options.title === "string" ? options.title : null;
  return Object.values(s.bookmarks.nodes)
    .filter((n) => !isRootId(ids, n.id) && bookmarkOwnedBy(s, ids, n.id))
    .filter((n) => {
      const nodeUrl = n.kind === "url" ? n.url : "";
      if (url !== null && nodeUrl !== url) return false;
      if (title !== null && n.title !== title) return false;
      const haystack = `${n.title} ${nodeUrl}`.toLowerCase();
      return words.every((w) => haystack.includes(w));
    })
    .map((n) => chromeBookmark(s, ids, n.id, 0)!)
    .filter(Boolean);
}

function writableBookmark(s: BrowserState, ids: BookmarkIds, id: unknown) {
  const key = bookmarkTarget(s, ids, id);
  if (isRootId(ids, key)) fail("Can't modify the root bookmark folders.");
  return key;
}

const bookmarkContext = (call: WebKitExtensionCall, s: BrowserState) => {
  const profileId = appProfileOf(s, call.base);
  if (!profileId) fail("Bookmarks aren't ready.");
  return { profileId: profileId!, ids: bookmarkIds(call.base) };
};

const bookmarks: Record<string, Handler> = {
  getTree: (call, s) => [bookmarkTreeRoot(s, bookmarkIds(call.base), Infinity)],
  getSubTree: (call, s) => {
    const ids = bookmarkIds(call.base);
    if (call.args[0] === "0") return [bookmarkTreeRoot(s, ids, Infinity)];
    return [chromeBookmark(s, ids, bookmarkTarget(s, ids, call.args[0]), Infinity)];
  },
  get: (call, s) => {
    const ids = bookmarkIds(call.base);
    const list = Array.isArray(call.args[0]) ? call.args[0] : [call.args[0]];
    return list.map((id) => (id === "0" ? bookmarkTreeRoot(s, ids, 0) : chromeBookmark(s, ids, bookmarkTarget(s, ids, id), 0)));
  },
  getChildren: (call, s) => {
    const ids = bookmarkIds(call.base);
    if (call.args[0] === "0") return bookmarkTreeRoot(s, ids, 1).children ?? [];
    return chromeBookmark(s, ids, bookmarkTarget(s, ids, call.args[0]), 1)?.children ?? [];
  },
  getRecent: (call, s) => {
    const ids = bookmarkIds(call.base);
    const count = typeof call.args[0] === "number" && call.args[0] > 0 ? call.args[0] : fail("numberOfItems cannot be less than 1.");
    return Object.values(s.bookmarks.nodes)
      .filter((n) => n.kind === "url" && bookmarkOwnedBy(s, ids, n.id))
      .sort((a, b) => b.addedAt - a.addedAt)
      .slice(0, count)
      .map((n) => chromeBookmark(s, ids, n.id, 0));
  },
  search: (call, s) => bookmarkSearch(s, bookmarkIds(call.base), call.args[0]),
  create: (call, s) => {
    const { profileId, ids } = bookmarkContext(call, s);
    const options = optionsOf(call.args[0]);
    const parentId = options.parentId === undefined ? ids.roots.other : bookmarkTarget(s, ids, options.parentId);
    if (s.bookmarks.nodes[parentId]?.kind !== "folder") fail("Parent must be a folder.");
    const index = typeof options.index === "number" ? options.index : undefined;
    const title = textOf(options.title);
    const id = typeof options.url === "string"
      ? addBookmark({ profileId, url: options.url, title, parentId, index })
      : addBookmarkFolder({ profileId, title, parentId, index });
    return chromeBookmark(store(), ids, id, 0);
  },
  move: (call, s) => {
    const { ids } = bookmarkContext(call, s);
    const key = writableBookmark(s, ids, call.args[0]);
    const destination = optionsOf(call.args[1]);
    const parentId = destination.parentId === undefined ? s.bookmarks.nodes[key]!.parentId! : bookmarkTarget(s, ids, destination.parentId);
    if (s.bookmarks.nodes[parentId]?.kind !== "folder") fail("Parent must be a folder.");
    moveBookmark(key, parentId, typeof destination.index === "number" ? destination.index : undefined);
    return chromeBookmark(store(), ids, key, 0);
  },
  update: (call, s) => {
    const { ids } = bookmarkContext(call, s);
    const key = writableBookmark(s, ids, call.args[0]);
    const changes = optionsOf(call.args[1]);
    updateBookmark(key, {
      ...(typeof changes.title === "string" ? { title: changes.title } : {}),
      ...(typeof changes.url === "string" ? { url: changes.url } : {}),
    });
    return chromeBookmark(store(), ids, key, 0);
  },
  remove: (call, s) => {
    const { ids } = bookmarkContext(call, s);
    const key = writableBookmark(s, ids, call.args[0]);
    const node = s.bookmarks.nodes[key]!;
    if (node.kind === "folder" && node.children.length) fail("Can't remove non-empty folder (use recursive to force).");
    removeBookmark(key);
  },
  removeTree: (call, s) => {
    const { ids } = bookmarkContext(call, s);
    removeBookmark(writableBookmark(s, ids, call.args[0]));
  },
};

function groupTarget(call: WebKitExtensionCall, s: BrowserState, id: unknown) {
  const key = keyFor("group", id);
  const group = key ? groupsFor(s, call.profile).find((g) => g.id === key) : undefined;
  return group ?? fail(`No group with id: ${String(id)}.`);
}

const refsOf = (call: WebKitExtensionCall) => ({ tabKeys: call.tabKeys, windows: call.windows });

const tabsOf = (call: WebKitExtensionCall, value: unknown) =>
  (Array.isArray(value) ? value : [value]).map((ref) => tabOfRef(refsOf(call), ref)).filter((key): key is string => !!key);

const tabGroups: Record<string, Handler> = {
  get: (call, s) => chromeTabGroup(s, groupTarget(call, s, call.args[0])),
  query: (call, s) => {
    const info = optionsOf(call.args[0]);
    const windowId = info.windowId === undefined ? undefined : windowOfRef(s, refsOf(call), info.windowId);
    return groupsFor(s, call.profile)
      .filter((g) => windowId === undefined || g.windowId === windowId)
      .filter((g) => typeof info.collapsed !== "boolean" || g.collapsed === info.collapsed)
      .map((g) => chromeTabGroup(s, g))
      .filter((g) => typeof info.color !== "string" || g.color === info.color)
      .filter((g) => typeof info.title !== "string" || g.title === info.title);
  },
  update: (call, s) => {
    const group = groupTarget(call, s, call.args[0]);
    const changes = optionsOf(call.args[1]);
    updateGroup(group.id, {
      ...(typeof changes.collapsed === "boolean" ? { collapsed: changes.collapsed } : {}),
      ...(typeof changes.title === "string" ? { name: changes.title } : {}),
      ...(isChromeColor(changes.color) ? { color: changes.color } : {}),
    });
    return chromeTabGroup(store(), store().groups[group.id] ?? group);
  },
  move: (call, s) => chromeTabGroup(s, groupTarget(call, s, call.args[0])),
  group: (call, s) => {
    const options = optionsOf(call.args[0]);
    const tabs = tabsOf(call, options.tabIds);
    if (!tabs.length) fail("No tab with the given ids.");
    if (options.groupId !== undefined) {
      const group = groupTarget(call, s, options.groupId);
      addTabsToGroup(group.id, tabs);
      return numberFor("group", group.id);
    }
    const made = groupTabs(tabs, { pinned: false });
    return made ? numberFor("group", made) : fail("These tabs can't be grouped.");
  },
  ungroup: (call) => void removeTabsFromGroup(tabsOf(call, optionsOf(call.args[0]).tabIds)),
  groupIdsOf: (call, s) => call.tabKeys.map((key) => chromeGroupIdOf(s, key)),
};

const handlers: Record<string, Record<string, Handler>> = { downloads, history, bookmarks, tabGroups };

export async function answerExtensionCall(call: WebKitExtensionCall): Promise<{ result: unknown } | { error: string }> {
  const handler = handlers[call.api]?.[call.method];
  if (!handler) return { error: `${call.api}.${call.method} isn't supported.` };
  try {
    const result = await handler(call, store());
    return { result: result === undefined ? null : result };
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error) };
  }
}
