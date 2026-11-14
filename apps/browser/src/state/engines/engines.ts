import type { PageEngine } from "../../platform/tabs";
import type { BrowserState } from "../browser/store";
import type { Tab } from "../browser/types";
import { isWebPageUrl } from "../../lib/url";
import { adoptKind } from "../tabs/adoptIds";
import { adoptOf, navigationOf } from "../tabs/pageSession";

export type { PageEngine } from "../../platform/tabs";

export const ENGINE_NAMES: Record<PageEngine, string> = { chromium: "Chromium", webkit: "WebKit" };
export const ENGINE_SYMBOLS: Record<PageEngine, string> = { chromium: "globe", webkit: "safari" };
export const RECOMMENDED_ENGINE: PageEngine = "chromium";
export const otherEngine = (engine: PageEngine): PageEngine => (engine === "webkit" ? "chromium" : "webkit");

type EngineState = Pick<BrowserState, "tabs" | "settings">;

export function siteOf(url: string | undefined | null): string | null {
  if (!url) return null;
  try {
    const u = new URL(url);
    return u.protocol === "http:" || u.protocol === "https:" ? `${u.protocol}//${u.host}`.toLowerCase() : null;
  } catch {
    return null;
  }
}

export const chromiumOnly = (url: string | undefined | null) => !!url && /^(ardia|chrome|chrome-extension|chrome-untrusted|devtools|view-source):/i.test(url);
export const webStorePage = (url: string | undefined | null) => !!url && /^https:\/\/(chromewebstore\.google\.com|chrome\.google\.com\/webstore)([/?#]|$)/i.test(url);
export const needsChromium = (url: string | undefined | null) => chromiumOnly(url) || webStorePage(url);
export const canSwitchEngine = (url: string | undefined | null) => !!url && isWebPageUrl(url) && !webStorePage(url);

export type EngineMode = BrowserState["settings"]["engineMode"];

export const engineMode = (s: Pick<BrowserState, "settings">): EngineMode => (s.settings.engineMode === "chromium" || s.settings.engineMode === "webkit" ? s.settings.engineMode : "automatic");
export const singleEngine = (s: Pick<BrowserState, "settings">): PageEngine | null => {
  const mode = engineMode(s);
  return mode === "automatic" ? null : mode;
};
const modeEngine = (s: Pick<BrowserState, "settings">, url: string | undefined | null): PageEngine | undefined => {
  const only = singleEngine(s);
  return only ? (needsChromium(url) ? "chromium" : only) : undefined;
};

export const switchableEngine = (s: Pick<BrowserState, "settings">, url: string | undefined | null) => !singleEngine(s) && canSwitchEngine(url);

export const defaultEngine = (s: Pick<BrowserState, "settings">): PageEngine => singleEngine(s) ?? (s.settings.pageEngine === "webkit" ? "webkit" : "chromium");

export function ruleFor(s: Pick<BrowserState, "settings">, url: string | undefined | null): PageEngine | undefined {
  const site = siteOf(url);
  return site && !singleEngine(s) ? s.settings.websiteEngines?.[site] : undefined;
}

export const PROTECTED_VIDEO_SITES: readonly string[] = [
  "netflix.com",
  "disneyplus.com",
  "max.com",
  "hbomax.com",
  "primevideo.com",
  "hulu.com",
  "tv.apple.com",
  "music.apple.com",
  "peacocktv.com",
  "paramountplus.com",
  "crunchyroll.com",
  "hotstar.com",
  "jiohotstar.com",
  "v.qq.com",
];

export function protectedVideoSite(url: string | undefined | null): boolean {
  const site = siteOf(url);
  if (!site?.startsWith("https://")) return false;
  const host = new URL(site).hostname;
  return PROTECTED_VIDEO_SITES.some((domain) => host === domain || host.endsWith(`.${domain}`));
}

export const builtInEngine = (s: Pick<BrowserState, "settings">, url: string | undefined | null): PageEngine | undefined =>
  !singleEngine(s) && s.settings.protectedVideoInWebKit === true && protectedVideoSite(url) ? "webkit" : undefined;

export const chosenEngine = (s: Pick<BrowserState, "settings">, url: string | undefined | null): PageEngine | undefined =>
  modeEngine(s, url) ?? (webStorePage(url) ? "chromium" : undefined) ?? ruleFor(s, url) ?? builtInEngine(s, url);

export const recommendedEngineFor = (s: Pick<BrowserState, "settings">, url: string | undefined | null): PageEngine => modeEngine(s, url) ?? builtInEngine(s, url) ?? defaultEngine(s);

export const engineForUrl = (s: Pick<BrowserState, "settings">, url: string | undefined | null): PageEngine => chosenEngine(s, url) ?? defaultEngine(s);

const fromAdoption = (s: EngineState, t: Tab, depth: number): PageEngine | undefined => {
  const id = adoptKind(adoptOf(t));
  if (id?.kind === "webkit") return "webkit";
  if (id?.kind === "ardiacore" || id?.kind === "tab") return "chromium";
  if (id?.kind !== "clone") return undefined;
  const source = s.tabs[id.key];
  return source && depth < 8 ? engineOf(s, source, depth + 1) : undefined;
};

export const drivenByChrome = (s: EngineState, t: Tab, depth = 0): boolean => {
  if (t.chromeOpened) return true;
  const id = adoptKind(adoptOf(t));
  if (id?.kind === "tab") return true;
  const opener = id?.kind === "ardiacore" && t.openerId ? s.tabs[t.openerId] : undefined;
  return !!opener && depth < 8 && drivenByChrome(s, opener, depth + 1);
};

function engineOf(s: EngineState, t: Tab, depth: number): PageEngine {
  if (needsChromium(navigationOf(t)?.url ?? t.url)) return "chromium";
  const only = singleEngine(s);
  if (only === "webkit" && drivenByChrome(s, t, depth)) return "chromium";
  if (only) return only;
  if (t.engine) return t.engine;
  const adopted = fromAdoption(s, t, depth);
  if (adopted) return adopted;
  const opener = t.openerId ? s.tabs[t.openerId] : undefined;
  if (opener?.engine && (opener.url || navigationOf(opener))) return opener.engine;
  return engineForUrl(s, navigationOf(t)?.url ?? t.url);
}

export function tabEngine(s: EngineState, tabId: string): PageEngine {
  const t = s.tabs[tabId];
  return t ? engineOf(s, t, 0) : defaultEngine(s);
}

export function engineUnderMode(s: EngineState, t: Tab): PageEngine {
  if (singleEngine(s)) return engineOf(s, t, 0);
  const { engine: _, ...unpinned } = t;
  return engineOf(s, unpinned, 0);
}

export function modeEngineFor(s: EngineState, t: Tab, url: string): PageEngine | undefined {
  const only = singleEngine(s);
  if (!only) return undefined;
  if (needsChromium(url)) return "chromium";
  return only === "webkit" && drivenByChrome(s, t, 0) ? "chromium" : only;
}

export function typedNavigationEngine(s: EngineState, tab: Tab, url: string): PageEngine {
  if (needsChromium(url)) return "chromium";
  const chosen = chosenEngine(s, url);
  if (chosen) return chosen;
  return tab.url || navigationOf(tab) ? tabEngine(s, tab.id) : defaultEngine(s);
}

export type WebKitPage = { url: string; title: string; isLoading: boolean; committedUrl: string };
export type RecordedVisit = { url: string; title: string; at: number };
type Visit = RecordedVisit & { staleTitle: string; profile: string | null; timer?: unknown };
type VisitTimers = { set(run: () => void, ms: number): unknown; clear(handle: unknown): void };

export const VISIT_SETTLE_MS = 1500;

export function visitRecorder(write: (profile: string, visit: RecordedVisit) => void, timers: VisitTimers, now: () => number) {
  const open = new Map<string, Visit>();
  const done = new Map<string, string>();
  const finish = (tabId: string, visit: Visit) => {
    if (visit.timer !== undefined) timers.clear(visit.timer);
    visit.timer = undefined;
    if (open.get(tabId) === visit) open.delete(tabId);
    done.set(tabId, visit.url);
    if (visit.profile !== null) write(visit.profile, { url: visit.url, title: visit.title, at: visit.at });
  };
  return {
    note(tabId: string, profile: string | null, page: WebKitPage) {
      const { url, title, isLoading, committedUrl } = page;
      if (!/^https?:/i.test(url) || url !== committedUrl) return;
      let visit = open.get(tabId);
      if (visit && visit.url !== url) {
        finish(tabId, visit);
        visit = undefined;
      }
      if (!visit) {
        if (done.get(tabId) === url) return;
        done.delete(tabId);
        visit = { url, title, at: now(), staleTitle: title, profile };
        open.set(tabId, visit);
      } else if (title) visit.title = title;
      if (title && title !== visit.staleTitle) return finish(tabId, visit);
      if (isLoading || visit.timer !== undefined) return;
      const settling = visit;
      settling.timer = timers.set(() => {
        if (open.get(tabId) === settling) finish(tabId, settling);
      }, VISIT_SETTLE_MS);
    },
    close(tabId: string) {
      const visit = open.get(tabId);
      if (visit) finish(tabId, visit);
      open.delete(tabId);
      done.delete(tabId);
    },
    size: () => open.size + done.size,
  };
}
