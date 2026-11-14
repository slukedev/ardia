import { TAB_GROUP_COLORS } from "@ardia/core";
import type { Download } from "../../platform/downloads";
import type { BrowserState } from "../browser/store";
import type { BookmarkNode, HistoryEntry, TabGroup } from "../browser/types";
import { engineProfile } from "../browser/model";
import { rootIdsFor } from "../bookmarks/bookmarks";
import { rootOf } from "../groups/groups";
import { groupOf } from "../pins/tabGrouping";

const numbers = new Map<string, number>();
const keys = new Map<string, string>();
let lastNumber = 0;

export function numberFor(kind: string, key: string): number {
  const name = `${kind}\u0000${key}`;
  let n = numbers.get(name);
  if (n === undefined) {
    n = ++lastNumber;
    numbers.set(name, n);
    keys.set(`${kind}\u0000${n}`, key);
  }
  return n;
}

export const keyFor = (kind: string, n: unknown): string | undefined =>
  typeof n === "number" || typeof n === "string" ? keys.get(`${kind}\u0000${Number(n)}`) : undefined;

export type WindowRef = { __windowTabs: string[] };

export const windowRef = (s: Pick<BrowserState, "windows">, windowId: string): WindowRef => ({ __windowTabs: [...(s.windows[windowId]?.tabIds ?? [])] });

export type CallRefs = { tabKeys: (string | null)[]; windows: string[][] };

export function tabOfRef(refs: CallRefs, value: unknown): string | null {
  const at = value && typeof value === "object" ? (value as { __tab?: unknown }).__tab : undefined;
  return typeof at === "number" ? (refs.tabKeys[at] ?? null) : null;
}

export function windowOfRef(s: Pick<BrowserState, "tabs">, refs: CallRefs, value: unknown): string | null {
  const at = value && typeof value === "object" ? (value as { __window?: unknown }).__window : undefined;
  if (typeof at !== "number") return null;
  for (const key of refs.windows[at] ?? []) {
    const windowId = s.tabs[key]?.windowId;
    if (windowId) return windowId;
  }
  return null;
}

export const appProfileOf = (s: Pick<BrowserState, "profiles" | "profileOrder">, engine: string) =>
  s.profileOrder.find((id) => engineProfile(s, id) === engine) ?? null;

export type ChromeDownload = {
  id: number;
  url: string;
  finalUrl: string;
  referrer: string;
  filename: string;
  incognito: boolean;
  danger: "safe" | "file";
  mime: string;
  startTime: string;
  endTime?: string;
  state: "in_progress" | "interrupted" | "complete";
  paused: boolean;
  canResume: boolean;
  error?: string;
  bytesReceived: number;
  totalBytes: number;
  fileSize: number;
  exists: boolean;
};

const seenAt = new Map<string, number>();
const endedAt = new Map<string, number>();

export function chromeDownload(d: Download, now = Date.now()): ChromeDownload {
  if (!seenAt.has(d.id)) seenAt.set(d.id, now);
  const done = d.state !== "downloading";
  if (done && !endedAt.has(d.id)) endedAt.set(d.id, now);
  const state = d.state === "finished" ? "complete" : d.state === "downloading" ? "in_progress" : "interrupted";
  return {
    id: numberFor("download", d.id),
    url: d.url,
    finalUrl: d.url,
    referrer: "",
    filename: d.path,
    incognito: !!d.offTheRecord,
    danger: d.dangerous ? "file" : "safe",
    mime: d.mimeType,
    startTime: new Date(seenAt.get(d.id)!).toISOString(),
    ...(done ? { endTime: new Date(endedAt.get(d.id)!).toISOString() } : {}),
    state,
    paused: d.paused,
    canResume: d.state === "downloading" && d.paused,
    ...(d.state === "cancelled" ? { error: "USER_CANCELED" } : d.state === "failed" ? { error: "NETWORK_FAILED" } : {}),
    bytesReceived: d.received,
    totalBytes: d.total > 0 ? d.total : -1,
    fileSize: d.state === "finished" ? d.received : d.total > 0 ? d.total : -1,
    exists: d.state === "finished",
  };
}

export function downloadsFor(s: Pick<BrowserState, "downloads">, profile: string, base: string, isPrivate: boolean): Download[] {
  return s.downloads.filter((d) => {
    const owner = d.profile ?? "";
    if (isPrivate) return owner === profile || (owner === base && !d.offTheRecord);
    return owner === profile && !d.offTheRecord;
  });
}

export type ChromeHistoryItem = { id: string; url: string; title: string; lastVisitTime: number; visitCount: number; typedCount: number };

export const chromeHistoryItem = (h: HistoryEntry): ChromeHistoryItem => ({
  id: String(numberFor("history", h.url)),
  url: h.url,
  title: h.title,
  lastVisitTime: h.lastVisit,
  visitCount: h.visits,
  typedCount: 0,
});

export type ChromeBookmark = {
  id: string;
  parentId?: string;
  index?: number;
  url?: string;
  title: string;
  dateAdded: number;
  syncing: boolean;
  folderType?: "bookmarks-bar" | "other";
  children?: ChromeBookmark[];
};

export const BOOKMARK_ROOT = "0";
const BAR = "1";
const OTHER = "2";

export type BookmarkIds = { toChrome(id: string): string; fromChrome(id: unknown): string | null; roots: { bar: string; other: string } };

export function bookmarkIds(engine: string): BookmarkIds {
  const roots = rootIdsFor(engine);
  return {
    roots,
    toChrome: (id) => (id === roots.bar ? BAR : id === roots.other ? OTHER : id),
    fromChrome: (id) => {
      if (typeof id !== "string") return null;
      if (id === BAR) return roots.bar;
      if (id === OTHER) return roots.other;
      return id === BOOKMARK_ROOT ? null : id;
    },
  };
}

export function bookmarkOwnedBy(s: Pick<BrowserState, "bookmarks">, ids: BookmarkIds, id: string): boolean {
  let node: BookmarkNode | undefined = s.bookmarks.nodes[id];
  for (let i = 0; node && i < 200; i++) {
    if (node.id === ids.roots.bar || node.id === ids.roots.other) return true;
    node = node.parentId ? s.bookmarks.nodes[node.parentId] : undefined;
  }
  return false;
}

export function chromeBookmark(s: Pick<BrowserState, "bookmarks">, ids: BookmarkIds, id: string, depth: number): ChromeBookmark | null {
  const node = s.bookmarks.nodes[id];
  if (!node) return null;
  const parent = node.parentId ? s.bookmarks.nodes[node.parentId] : undefined;
  const isRoot = id === ids.roots.bar || id === ids.roots.other;
  const out: ChromeBookmark = {
    id: ids.toChrome(id),
    parentId: isRoot ? BOOKMARK_ROOT : parent ? ids.toChrome(parent.id) : BOOKMARK_ROOT,
    index: isRoot ? (id === ids.roots.bar ? 0 : 1) : parent?.kind === "folder" ? Math.max(0, parent.children.indexOf(id)) : 0,
    title: node.title,
    dateAdded: node.addedAt,
    syncing: false,
  };
  if (isRoot) out.folderType = id === ids.roots.bar ? "bookmarks-bar" : "other";
  if (node.kind === "url") out.url = node.url;
  else if (depth > 0) out.children = node.children.map((c) => chromeBookmark(s, ids, c, depth - 1)).filter((c): c is ChromeBookmark => !!c);
  return out;
}

export function bookmarkTreeRoot(s: Pick<BrowserState, "bookmarks">, ids: BookmarkIds, depth: number): ChromeBookmark {
  const children = depth > 0 ? [ids.roots.bar, ids.roots.other].map((id) => chromeBookmark(s, ids, id, depth - 1)).filter((c): c is ChromeBookmark => !!c) : undefined;
  return { id: BOOKMARK_ROOT, title: "", dateAdded: 0, syncing: false, ...(children ? { children } : {}) };
}

export type ChromeTabGroup = { id: number; collapsed: boolean; color: string; title: string; windowId: WindowRef; shared: boolean };

const CHROME_COLORS = new Set<string>(TAB_GROUP_COLORS);

export const chromeColorOf = (color: TabGroup["color"]) => (color && CHROME_COLORS.has(color) ? color : "grey");

export const isChromeColor = (color: unknown): color is (typeof TAB_GROUP_COLORS)[number] => typeof color === "string" && CHROME_COLORS.has(color);

export function groupsFor(s: Pick<BrowserState, "groups" | "profiles">, profile: string): TabGroup[] {
  return Object.values(s.groups).filter((g) => !g.parentId && !g.pinned && engineProfile(s, g.profileId) === profile);
}

export const chromeTabGroup = (s: Pick<BrowserState, "windows">, g: TabGroup): ChromeTabGroup => ({
  id: numberFor("group", g.id),
  collapsed: g.collapsed,
  color: chromeColorOf(g.color),
  title: g.name,
  windowId: windowRef(s, g.windowId),
  shared: false,
});

export function chromeGroupIdOf(s: Pick<BrowserState, "groups">, tabKey: string | null): number {
  const inner = tabKey ? groupOf(s, tabKey) : undefined;
  const root = inner && rootOf(s.groups, inner.id);
  return root && !root.pinned ? numberFor("group", root.id) : -1;
}
