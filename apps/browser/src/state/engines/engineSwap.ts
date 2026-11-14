import { create } from "zustand";
import type { PageEngine } from "../../platform/tabs";
import { setWebKitZoom } from "../../platform/webkit";
import { setZoom } from "../../platform/siteSettings";
import { webviews } from "../../platform/webviews";
import { withDeadline } from "../../lib/deadline";
import { useBrowser } from "../browser/store";
import { engineProfile } from "../browser/model";
import { noteEngineSwap } from "../telemetry/engineSwitchCounts";

export type RetiringPage = { engine: PageEngine };

export const useRetiringPages = create<Record<string, RetiringPage>>()(() => ({}));

type Swap = { from: PageEngine; to: PageEngine; scroll: { x: number; y: number } | null; zoom: boolean; startedAt: number; watching: boolean };

const swaps = new Map<string, Swap>();

export const SWAP_DEADLINE_MS = 3000;
const POLL_MS = 50;
const EVALUATE_MS = 400;

const SCROLL_POSITION = `post("result", JSON.stringify({ x: scrollX, y: scrollY }))`;

export const firstPaintScript = (scroll: { x: number; y: number } | null) => `(() => {
  const shown = /^(https?|file):$/.test(location.protocol) && location.href !== "about:blank";
  const painted = shown && (performance.getEntriesByName("first-contentful-paint").length > 0 || document.readyState === "complete");
  if (!painted) return post("result", "false");
  const target = ${scroll ? JSON.stringify(scroll) : "null"};
  if (target && target.y > 0) {
    const room = Math.max(0, (document.scrollingElement || document.documentElement).scrollHeight - innerHeight);
    if (room + 1 < target.y && document.readyState !== "complete") return post("result", "false");
    if (Math.abs(scrollY - Math.min(target.y, room)) > 1 || Math.abs(scrollX - target.x) > 1) scrollTo(target.x, Math.min(target.y, room));
  }
  requestAnimationFrame(() => requestAnimationFrame(() => post("result", "true")));
})()`;

const hostOf = (url: string) => {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
};

async function carryZoom(tabId: string, to: PageEngine, url: string): Promise<boolean> {
  const s = useBrowser.getState();
  const t = s.tabs[tabId];
  const host = hostOf(url);
  if (!t || !host || !Number.isFinite(t.zoom) || t.zoom <= 0) return false;
  const profile = engineProfile(s, t.profileId);
  const write = to === "webkit" ? setWebKitZoom(profile, host, t.zoom) : setZoom(profile, host, t.zoom);
  return (await withDeadline(write.then(() => true).catch(() => false), EVALUATE_MS, false)) && Math.abs(t.zoom - 1) > 0.001;
}

export async function holdPageForSwap(tabId: string, from: PageEngine, to: PageEngine, url: string, keepScroll: boolean) {
  const web = webviews.get(tabId);
  const at = keepScroll && web ? await withDeadline(web.evaluate<{ x: number; y: number }>(SCROLL_POSITION).catch(() => null), EVALUATE_MS, null) : null;
  const scroll = at && Number.isFinite(at.x) && Number.isFinite(at.y) && (at.x > 0 || at.y > 0) ? { x: Math.round(at.x), y: Math.round(at.y) } : null;
  const zoom = await carryZoom(tabId, to, url);
  const swap: Swap = { from, to, scroll, zoom, startedAt: Date.now(), watching: false };
  swaps.set(tabId, swap);
  useRetiringPages.setState({ [tabId]: { engine: from } });
  setTimeout(() => !swap.watching && finish(tabId, swap, true, true), SWAP_DEADLINE_MS * 2);
}

export const swapping = (tabId: string) => swaps.has(tabId);

export function dropSwap(tabId: string) {
  swaps.delete(tabId);
  if (!useRetiringPages.getState()[tabId]) return;
  useRetiringPages.setState((pages) => {
    const { [tabId]: _, ...rest } = pages;
    return rest;
  }, true);
}

function finish(tabId: string, swap: Swap, timedOut: boolean, hidden: boolean) {
  if (swaps.get(tabId) !== swap) return;
  dropSwap(tabId);
  noteEngineSwap(swap.to, { ms: Date.now() - swap.startedAt, timedOut, hidden, scroll: !!swap.scroll, zoom: swap.zoom });
}

export function watchFirstPaint(tabId: string, engine: PageEngine, visible: boolean) {
  const swap = swaps.get(tabId);
  if (!swap || swap.watching || swap.to !== engine) return;
  swap.watching = true;
  if (!visible && !swap.scroll) return finish(tabId, swap, false, true);
  const script = firstPaintScript(swap.scroll);
  const tick = async () => {
    if (swaps.get(tabId) !== swap) return;
    const web = webviews.get(tabId);
    const painted = web ? await withDeadline(web.evaluate<boolean>(script).catch(() => null), EVALUATE_MS, null) : null;
    if (swaps.get(tabId) !== swap) return;
    if (painted === true) return finish(tabId, swap, false, !visible);
    if (Date.now() - swap.startedAt >= SWAP_DEADLINE_MS) return finish(tabId, swap, true, !visible);
    setTimeout(() => void tick(), POLL_MS);
  };
  void tick();
}
