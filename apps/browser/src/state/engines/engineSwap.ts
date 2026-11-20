import { create } from "zustand";
import type { PageEngine } from "../../platform/tabs";
import { setWebKitZoom } from "../../platform/webkit";
import { setZoom } from "../../platform/siteSettings";
import { webviews } from "../../platform/webviews";
import { withDeadline } from "../../lib/deadline";
import { useBrowser } from "../browser/store";
import { engineProfile } from "../browser/model";
import { noteEngineSwap } from "../telemetry/engineSwitchCounts";
import { consentToken, type ConsentToken } from "../telemetry/client";
import { updateLive } from "../tabs/actions";
import { setPageProgress } from "../tabs/pageProgress";

export type RetiringPage = { engine: PageEngine };

export const useRetiringPages = create<Record<string, RetiringPage>>()(() => ({}));

type HeldLive = { isLoading?: boolean; progress?: number };

export type Swap = {
  from: PageEngine;
  to: PageEngine;
  scroll: { x: number; y: number } | null;
  zoom: boolean;
  startedAt: number;
  consent: ConsentToken | null;
  watching: boolean;
  visible: boolean;
  deadline: ReturnType<typeof setTimeout> | null;
  held: HeldLive;
};

const swaps = new Map<string, Swap>();

export const SWAP_DEADLINE_MS = 3000;
const POLL_MS = 50;
const HIDDEN_POLL_MS = 250;
const EVALUATE_MS = 400;

const SCROLL_POSITION = `post("result", JSON.stringify({ x: scrollX, y: scrollY }))`;

export const firstPaintScript = (scroll: { x: number; y: number } | null, onScreen: boolean) => `(() => {
  const shown = /^(https?|file):$/.test(location.protocol) && location.href !== "about:blank";
  const painted = shown && (performance.getEntriesByName("first-contentful-paint").length > 0 || document.readyState === "complete");
  if (!painted) return post("result", "false");
  const target = ${scroll ? JSON.stringify(scroll) : "null"};
  if (target && target.y > 0) {
    const room = Math.max(0, (document.scrollingElement || document.documentElement).scrollHeight - innerHeight);
    if (room + 1 < target.y && document.readyState !== "complete") return post("result", "false");
    if (Math.abs(scrollY - Math.min(target.y, room)) > 1 || Math.abs(scrollX - target.x) > 1) scrollTo(target.x, Math.min(target.y, room));
  }
  ${onScreen ? `requestAnimationFrame(() => requestAnimationFrame(() => post("result", "true")));` : `post("result", "true");`}
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

export async function holdPageForSwap(tabId: string, from: PageEngine, to: PageEngine, url: string, keepScroll: boolean, stillWanted: () => boolean = () => true): Promise<Swap | null> {
  const consent = consentToken();
  if (!useBrowser.getState().settings.engineSwitchKeepsPage) {
    await carryZoom(tabId, to, url);
    return null;
  }
  const web = webviews.get(tabId);
  const at = keepScroll && web ? await withDeadline(web.evaluate<{ x: number; y: number }>(SCROLL_POSITION).catch(() => null), EVALUATE_MS, null) : null;
  const scroll = at && Number.isFinite(at.x) && Number.isFinite(at.y) && (at.x > 0 || at.y > 0) ? { x: Math.round(at.x), y: Math.round(at.y) } : null;
  if (!stillWanted()) return null;
  const zoom = await carryZoom(tabId, to, url);
  if (!stillWanted() || !useBrowser.getState().tabs[tabId]) return null;
  const replaced = swaps.get(tabId);
  const swap: Swap = { from, to, scroll, zoom, startedAt: Date.now(), consent, watching: false, visible: false, deadline: null, held: { ...replaced?.held } };
  if (replaced?.deadline) clearTimeout(replaced.deadline);
  swaps.set(tabId, swap);
  useRetiringPages.setState({ [tabId]: { engine: from } });
  swap.deadline = setTimeout(() => finish(tabId, swap, true), SWAP_DEADLINE_MS);
  return swap;
}

export const swapping = (tabId: string) => swaps.has(tabId);

export function heldBySwap(tabId: string, live: HeldLive): boolean {
  const swap = swaps.get(tabId);
  if (!swap) return false;
  Object.assign(swap.held, live);
  return true;
}

function release(tabId: string, swap: Swap) {
  if (swap.deadline) clearTimeout(swap.deadline);
  swap.deadline = null;
  swaps.delete(tabId);
  if (useRetiringPages.getState()[tabId])
    useRetiringPages.setState((pages) => {
      const { [tabId]: _, ...rest } = pages;
      return rest;
    }, true);
  if (!useBrowser.getState().tabs[tabId]) return;
  const { isLoading, progress } = swap.held;
  if (isLoading !== undefined) updateLive(tabId, { isLoading });
  if (progress !== undefined) setPageProgress(tabId, isLoading === false ? 0 : progress);
}

export function dropSwap(tabId: string, only?: Swap | null) {
  const swap = swaps.get(tabId);
  if (!swap || (only !== undefined && only !== swap)) return;
  release(tabId, swap);
}

function finish(tabId: string, swap: Swap, timedOut: boolean) {
  if (swaps.get(tabId) !== swap) return;
  release(tabId, swap);
  if (!useBrowser.getState().tabs[tabId]) return;
  const hidden = !swap.watching || !swap.visible;
  noteEngineSwap(swap.to, { ms: Date.now() - swap.startedAt, timedOut, hidden, scroll: !!swap.scroll, zoom: swap.zoom }, swap.consent);
}

export function watchFirstPaint(tabId: string, engine: PageEngine, visible: boolean) {
  const swap = swaps.get(tabId);
  if (!swap || swap.watching || swap.to !== engine) return;
  swap.watching = true;
  swap.visible = visible;
  if (!visible && !swap.scroll) return finish(tabId, swap, false);
  const script = firstPaintScript(swap.scroll, visible);
  const tick = async () => {
    if (swaps.get(tabId) !== swap) return;
    const web = webviews.get(tabId);
    const painted = web ? await withDeadline(web.evaluate<boolean>(script).catch(() => null), EVALUATE_MS, null) : null;
    if (swaps.get(tabId) !== swap) return;
    if (painted === true) return finish(tabId, swap, false);
    setTimeout(() => void tick(), visible ? POLL_MS : HIDDEN_POLL_MS);
  };
  void tick();
}
