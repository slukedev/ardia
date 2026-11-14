import { sendWebKitExtensionEvent, type WebKitExtensionApi, type WebKitExtensionListeners } from "../../platform/webkit";
import { useBrowser, type BrowserState } from "../browser/store";
import type { BookmarkNode, HistoryEntry } from "../browser/types";
import { historyOf } from "../history/history";
import {
  appProfileOf,
  bookmarkIds,
  bookmarkOwnedBy,
  chromeBookmark,
  chromeDownload,
  chromeHistoryItem,
  chromeTabGroup,
  downloadsFor,
  groupsFor,
  numberFor,
  type ChromeDownload,
} from "./webKitExtensionData";

type Listening = { base: string; private: boolean; apis: Set<WebKitExtensionApi> };
type Event = { api: WebKitExtensionApi; event: string; args: unknown[] };

const listening = new Map<string, Listening>();
let stop: (() => void) | null = null;

export function noteExtensionListeners(e: WebKitExtensionListeners) {
  if (e.apis.length) listening.set(e.profile, { base: e.base, private: e.private, apis: new Set(e.apis) });
  else listening.delete(e.profile);
  if (listening.size && !stop) stop = useBrowser.subscribe(changed);
  else if (!listening.size && stop) {
    stop();
    stop = null;
  }
}

export const listenedApis = (profile: string) => [...(listening.get(profile)?.apis ?? [])].sort();

function changed(s: BrowserState, prev: BrowserState) {
  for (const [profile, l] of listening) {
    const events = extensionEvents(s, prev, profile, l);
    for (const event of events) void sendWebKitExtensionEvent(profile, event).catch(() => {});
  }
}

export function extensionEvents(s: BrowserState, prev: BrowserState, profile: string, l: Listening): Event[] {
  const events: Event[] = [];
  if (l.apis.has("downloads") && s.downloads !== prev.downloads) events.push(...downloadEvents(s, prev, profile, l));
  if (l.apis.has("history") && s.history !== prev.history) events.push(...historyEvents(s, prev, l.base));
  if (l.apis.has("bookmarks") && s.bookmarks !== prev.bookmarks) events.push(...bookmarkEvents(s, prev, l.base));
  if (l.apis.has("tabGroups") && (s.groups !== prev.groups || s.windows !== prev.windows)) events.push(...groupEvents(s, prev, profile));
  return events;
}

const DELTA_FIELDS = ["url", "filename", "danger", "mime", "startTime", "endTime", "state", "canResume", "paused", "error", "totalBytes", "fileSize", "exists"] as const;

function downloadEvents(s: BrowserState, prev: BrowserState, profile: string, l: Listening): Event[] {
  const before = new Map(downloadsFor(prev, profile, l.base, l.private).map((d) => [d.id, chromeDownload(d)]));
  const now = downloadsFor(s, profile, l.base, l.private);
  const events: Event[] = [];
  for (const d of now) {
    const item = chromeDownload(d);
    const was = before.get(d.id);
    before.delete(d.id);
    if (!was) {
      events.push({ api: "downloads", event: "onCreated", args: [item] });
      continue;
    }
    const delta: Record<string, unknown> = { id: item.id };
    for (const field of DELTA_FIELDS) {
      const a = (was as Partial<ChromeDownload>)[field];
      const b = (item as Partial<ChromeDownload>)[field];
      if (a !== b) delta[field] = { ...(a !== undefined ? { previous: a } : {}), ...(b !== undefined ? { current: b } : {}) };
    }
    if (Object.keys(delta).length > 1) events.push({ api: "downloads", event: "onChanged", args: [delta] });
  }
  for (const gone of before.values()) events.push({ api: "downloads", event: "onErased", args: [gone.id] });
  return events;
}

function historyEvents(s: BrowserState, prev: BrowserState, base: string): Event[] {
  const profileId = appProfileOf(s, base);
  if (!profileId) return [];
  const before = historyOf(prev, profileId);
  const now = historyOf(s, profileId);
  if (before === now) return [];
  const was = new Map<string, HistoryEntry>(before.map((h) => [h.url, h]));
  const events: Event[] = [];
  for (const h of now) {
    const old = was.get(h.url);
    was.delete(h.url);
    if (!old || h.lastVisit > old.lastVisit) events.push({ api: "history", event: "onVisited", args: [chromeHistoryItem(h)] });
  }
  if (was.size) {
    const all = !now.length && before.length > 0;
    events.push({ api: "history", event: "onVisitRemoved", args: [{ allHistory: all, urls: all ? [] : [...was.keys()] }] });
  }
  return events;
}

type Place = { parentId: string; index: number; title: string; url?: string };

function bookmarkPlaces(s: Pick<BrowserState, "bookmarks">, base: string): Map<string, Place> {
  const ids = bookmarkIds(base);
  const places = new Map<string, Place>();
  const walk = (id: string) => {
    const node: BookmarkNode | undefined = s.bookmarks.nodes[id];
    if (node?.kind !== "folder") return;
    node.children.forEach((child, index) => {
      const c = s.bookmarks.nodes[child];
      if (!c) return;
      places.set(child, { parentId: id, index, title: c.title, ...(c.kind === "url" ? { url: c.url } : {}) });
      walk(child);
    });
  };
  walk(ids.roots.bar);
  walk(ids.roots.other);
  return places;
}

function bookmarkEvents(s: BrowserState, prev: BrowserState, base: string): Event[] {
  const ids = bookmarkIds(base);
  const before = bookmarkPlaces(prev, base);
  const now = bookmarkPlaces(s, base);
  const events: Event[] = [];
  const reordered = new Set<string>();
  for (const [id, place] of now) {
    const was = before.get(id);
    const chromeId = ids.toChrome(id);
    if (!was) {
      const node = chromeBookmark(s, ids, id, Infinity);
      if (node) events.push({ api: "bookmarks", event: "onCreated", args: [chromeId, node] });
      continue;
    }
    if (was.title !== place.title || was.url !== place.url) {
      events.push({ api: "bookmarks", event: "onChanged", args: [chromeId, { title: place.title, ...(place.url !== undefined ? { url: place.url } : {}) }] });
    }
    if (was.parentId !== place.parentId) {
      events.push({
        api: "bookmarks",
        event: "onMoved",
        args: [chromeId, { parentId: ids.toChrome(place.parentId), index: place.index, oldParentId: ids.toChrome(was.parentId), oldIndex: was.index }],
      });
    } else if (was.index !== place.index) reordered.add(place.parentId);
  }
  for (const [id, was] of before) {
    if (now.has(id)) continue;
    if (before.has(was.parentId) && !now.has(was.parentId)) continue;
    const node = chromeBookmark(prev, ids, id, Infinity);
    events.push({ api: "bookmarks", event: "onRemoved", args: [ids.toChrome(id), { parentId: ids.toChrome(was.parentId), index: was.index, ...(node ? { node } : {}) }] });
  }
  const changedParents = new Set(events.filter((e) => e.event !== "onChanged").map((e) => (e.args[1] as { parentId?: string }).parentId));
  for (const parentId of reordered) {
    const chromeParent = ids.toChrome(parentId);
    if (changedParents.has(chromeParent) || !bookmarkOwnedBy(s, ids, parentId)) continue;
    const folder = s.bookmarks.nodes[parentId];
    if (folder?.kind !== "folder") continue;
    events.push({ api: "bookmarks", event: "onChildrenReordered", args: [chromeParent, { childIds: folder.children.map(ids.toChrome) }] });
  }
  return events;
}

function groupEvents(s: BrowserState, prev: BrowserState, profile: string): Event[] {
  const before = new Map(groupsFor(prev, profile).map((g) => [g.id, g]));
  const events: Event[] = [];
  for (const g of groupsFor(s, profile)) {
    const was = before.get(g.id);
    before.delete(g.id);
    if (!was) events.push({ api: "tabGroups", event: "onCreated", args: [chromeTabGroup(s, g)] });
    else if (was.name !== g.name || was.color !== g.color || was.collapsed !== g.collapsed) events.push({ api: "tabGroups", event: "onUpdated", args: [chromeTabGroup(s, g)] });
  }
  for (const gone of before.values()) {
    events.push({ api: "tabGroups", event: "onRemoved", args: [{ ...chromeTabGroup(prev, gone), id: numberFor("group", gone.id) }] });
  }
  return events;
}
