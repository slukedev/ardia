import { addHistoryVisits } from "../../platform/history";
import type { PageEngine, ProtectedMediaRequest } from "../../platform/tabs";
import { confirm } from "../../platform/dialogs";
import { create } from "zustand";
import { storeTransaction, useBrowser } from "../browser/store";
import { pageOf, patchPage } from "../tabs/pageState";
import {
  canSwitchEngine,
  chosenEngine,
  chromiumOnly,
  drivenByChrome,
  ENGINE_NAMES,
  engineMode,
  engineUnderMode,
  modeEngineFor,
  needsChromium,
  singleEngine,
  siteOf,
  tabEngine,
  visitRecorder,
  webStorePage,
  type EngineMode,
  type WebKitPage,
} from "./engines";
import { engineProfile, isIncognitoProfile, navigationTo } from "../browser/model";
import type { Tab } from "../browser/types";
import { carrySignIn } from "./engineSignIn";
import { dropSwap, holdPageForSwap } from "./engineSwap";
import { syncExtensionsToWebKit } from "./webKitExtensions";
import { wantsPage } from "../tabs/tabPages";
import { webviews } from "../../platform/webviews";
import { withDeadline } from "../../lib/deadline";
import { loadedPage, navigationOf } from "../tabs/pageSession";
import { noteEngineModeChange } from "../telemetry/engineSwitchCounts";

export type EngineOffer = { site: string; host: string; keySystem: string; canRemember: boolean };

export const useEngineOffers = create<Record<string, EngineOffer>>()(() => ({}));

const store = () => useBrowser.getState();
const declinedSites = new Set<string>();
const movingTabs = new Set<string>();
const siteMoves = new Map<string, number>();
const SITE_MOVE_SPACING_MS = 10_000;
const hostLabel = (site: string) => new URL(site).hostname.replace(/^www\./, "");

const UNSAVED_WORK = `(() => {
  const fields = Array.from(document.querySelectorAll("input:not([type=hidden]):not([type=password]):not([type=submit]):not([type=button]), textarea, select"));
  const changed = (f) => f.type === "checkbox" || f.type === "radio" ? f.checked !== f.defaultChecked : f.tagName === "SELECT" ? Array.from(f.options).some((o) => o.selected !== o.defaultSelected) : f.value !== f.defaultValue;
  const editing = document.activeElement && document.activeElement.isContentEditable;
  post("result", JSON.stringify(fields.some(changed) || !!editing));
})()`;

async function hasUnsavedWork(tabId: string): Promise<boolean> {
  const web = webviews.get(tabId);
  if (!web) return false;
  return (await withDeadline(web.evaluate<boolean>(UNSAVED_WORK), 1500, null)) === true;
}

export function setWebsiteEngine(url: string, engine: PageEngine | null) {
  const site = siteOf(url);
  if (!site) return;
  const rules = { ...store().settings.websiteEngines };
  if (engine) rules[site] = engine;
  else delete rules[site];
  store().updateSettings({ websiteEngines: rules });
}

export function persistEngine(tabId: string, engine: PageEngine) {
  const s = store();
  const t = s.tabs[tabId];
  if (!t) return;
  const opened = engine === "chromium" && !t.chromeOpened && drivenByChrome(s, t);
  if (!t.engine || opened) s.updateTab(tabId, { ...(t.engine ? {} : { engine }), ...(opened ? { chromeOpened: true as const } : {}) });
}

async function mayLeavePage(t: Tab, title: string, message: string, confirmTitle: string): Promise<boolean> {
  if (!wantsPage(t) || !(await hasUnsavedWork(t.id))) return true;
  const { confirmed } = await confirm({ title, message, confirmTitle, cancelTitle: "Stay on Page", windowId: t.windowId });
  return confirmed;
}

const pageUrl = (t: Tab | undefined) => t?.url || navigationOf(t)?.url || "";

export async function goBackAcrossEngines(tabId: string): Promise<boolean> {
  const back = pageOf(tabId).engineBack;
  const t = store().tabs[tabId];
  if (!back || !t) return false;
  const forced = modeEngineFor(store(), t, back.url);
  if (forced && forced !== back.engine) {
    patchPage(tabId, { engineBack: null });
    return false;
  }
  const from = pageUrl(t);
  const leaving = await mayLeavePage(t, "Go back to the previous page?", `It opens in ${ENGINE_NAMES[back.engine]}, so changes you made on this page may not be saved.`, "Go Back");
  const now = store().tabs[tabId];
  if (!leaving || !now || pageUrl(now) !== from || pageOf(tabId).engineBack !== back) return false;
  patchPage(tabId, { engineBack: null });
  await holdPageForSwap(tabId, tabEngine(store(), tabId), back.engine, back.url, false);
  if (pageUrl(store().tabs[tabId]) !== from) {
    dropSwap(tabId);
    return false;
  }
  store().updateTab(tabId, { engine: back.engine, page: loadedPage(navigationTo(back.url, true)) });
  return true;
}

export async function openPageIn(tabId: string, engine: PageEngine, options: { rule?: PageEngine | null; checkWork?: boolean } = {}): Promise<boolean> {
  const t = store().tabs[tabId];
  if (!t) return false;
  const url = t.url || navigationOf(t)?.url || "";
  if (!canSwitchEngine(url) && !(engine === "chromium" && webStorePage(url))) return false;
  const forced = modeEngineFor(store(), t, url);
  if (forced && forced !== engine) return false;
  const saveRule = () => options.rule !== undefined && !isIncognitoProfile(t.profileId) && setWebsiteEngine(url, options.rule);
  clearEngineOffer(tabId);
  if (tabEngine(store(), tabId) === engine) {
    saveRule();
    return true;
  }
  if (options.checkWork !== false && !(await mayLeavePage(t, `Open this page in ${ENGINE_NAMES[engine]}?`, `The page reloads in ${ENGINE_NAMES[engine]}, so changes you made on it may not be saved.`, `Open in ${ENGINE_NAMES[engine]}`))) return false;
  await carrySignIn(tabId, url, engine);
  const from = tabEngine(store(), tabId);
  if (from !== engine && wantsPage(store().tabs[tabId])) await holdPageForSwap(tabId, from, engine, url, true);
  const now = store().tabs[tabId];
  if (!now || pageUrl(now) !== url) {
    dropSwap(tabId);
    return false;
  }
  saveRule();
  if (tabEngine(store(), tabId) === engine) {
    dropSwap(tabId);
    return true;
  }
  store().updateTab(tabId, wantsPage(now) ? { engine, page: loadedPage(navigationTo(now.url || url, true)) } : { engine });
  return true;
}

export const togglePageEngine = (tabId: string) => openPageIn(tabId, tabEngine(store(), tabId) === "webkit" ? "chromium" : "webkit");

export function offerWebKit(tabId: string, { keySystem }: ProtectedMediaRequest) {
  const s = store();
  const t = s.tabs[tabId];
  if (!t || singleEngine(s) || tabEngine(s, tabId) === "webkit") return;
  const site = siteOf(t.url);
  if (!site) return;
  const rule = chosenEngine(s, t.url);
  if (rule === "chromium" || declinedSites.has(site)) return;
  if (rule === "webkit") return void moveForProtectedVideo(tabId, site);
  if (useEngineOffers.getState()[tabId]?.site === site) return;
  useEngineOffers.setState({ [tabId]: { site, host: hostLabel(site), keySystem, canRemember: !isIncognitoProfile(t.profileId) } });
}

export function clearEngineOffer(tabId: string) {
  if (!useEngineOffers.getState()[tabId]) return;
  useEngineOffers.setState((offers) => {
    const { [tabId]: _, ...rest } = offers;
    return rest;
  }, true);
}

export function stayOnPage(tabId: string, remember = false) {
  const offer = useEngineOffers.getState()[tabId];
  if (offer) declinedSites.add(offer.site);
  if (offer && remember && offer.canRemember) setWebsiteEngine(offer.site, "chromium");
  clearEngineOffer(tabId);
}

export const acceptEngineOffer = (tabId: string) => openPageIn(tabId, "webkit", { rule: "webkit" });

async function moveForProtectedVideo(tabId: string, site: string) {
  if (movingTabs.has(tabId)) return;
  movingTabs.add(tabId);
  try {
    if (!(await openPageIn(tabId, "webkit"))) {
      declinedSites.add(site);
      return;
    }
  } finally {
    movingTabs.delete(tabId);
  }
}

function moveAfterNavigation(tabId: string, from: PageEngine, to: PageEngine, previousUrl: string) {
  const now = Date.now();
  if (now - (siteMoves.get(tabId) ?? 0) < SITE_MOVE_SPACING_MS) return;
  siteMoves.set(tabId, now);
  watchClosedTabs();
  void openPageIn(tabId, to, { checkWork: false }).then((moved) => {
    if (moved && (canSwitchEngine(previousUrl) || needsChromium(previousUrl))) patchPage(tabId, { engineBack: { engine: from, url: previousUrl } });
  });
}

export function followSiteChoice(tabId: string, engine: PageEngine, url: string, previousUrl: string) {
  const s = store();
  const t = s.tabs[tabId];
  if (!t) return;
  if (singleEngine(s)) {
    const forced = modeEngineFor(s, t, url);
    const followsMode = forced === "chromium" || chromiumOnly(previousUrl);
    if (forced && forced !== engine && followsMode && (canSwitchEngine(url) || needsChromium(url))) moveAfterNavigation(tabId, engine, forced, previousUrl);
    return;
  }
  const site = siteOf(url);
  if (!site || site === siteOf(previousUrl) || t.openerId) return;
  const chosen = chosenEngine(s, url);
  if (chosen && chosen !== engine) moveAfterNavigation(tabId, engine, chosen, previousUrl);
}

export const useEngineModeSwitch = create<{ pending: EngineMode | null }>()(() => ({ pending: null }));

const SWITCH_CONFIRM = {
  title: "Switch engines?",
  message: "Some pages reload in the other engine, so changes you made on them may not be saved.",
  confirmTitle: "Switch",
  cancelTitle: "Cancel",
};

async function carryEachSite(moves: { tab: Tab; to: PageEngine; url: string }[]) {
  const carried = new Set<string>();
  await Promise.all(
    moves.map(({ tab, to, url }) => {
      const key = `${tab.profileId}|${siteOf(url)}|${to}`;
      if (carried.has(key)) return;
      carried.add(key);
      return carrySignIn(tab.id, url, to);
    }),
  );
}

export async function setEngineMode(mode: EngineMode): Promise<boolean> {
  const before = store();
  if (useEngineModeSwitch.getState().pending || engineMode(before) === mode) return false;
  useEngineModeSwitch.setState({ pending: mode });
  try {
    const target = { ...before, settings: { ...before.settings, engineMode: mode } };
    const live = Object.values(before.tabs)
      .filter((tab) => wantsPage(tab) && !!pageUrl(tab))
      .map((tab) => ({ tab, from: tabEngine(before, tab.id), to: engineUnderMode(target, tab), url: pageUrl(tab) }))
      .filter((m) => m.from !== m.to);
    const unsaved = await Promise.all(live.map((m) => hasUnsavedWork(m.tab.id)));
    if (unsaved.some(Boolean) && !(await confirm(SWITCH_CONFIRM)).confirmed) {
      noteEngineModeChange({ cancelled: true, moved: 0 });
      return false;
    }
    await carryEachSite(live);
    await Promise.all(live.map((m) => holdPageForSwap(m.tab.id, m.from, m.to, m.url, true)));
    let moved = 0;
    storeTransaction(() => {
      const now = store();
      const next = { ...now, settings: { ...now.settings, engineMode: mode } };
      now.updateSettings({ engineMode: mode });
      for (const tab of Object.values(now.tabs)) {
        const from = tabEngine(now, tab.id);
        const to = engineUnderMode(next, tab);
        if (pageOf(tab.id).engineBack) patchPage(tab.id, { engineBack: null });
        if (from === to) {
          if (tab.engine && tab.engine !== to) now.updateTab(tab.id, { engine: to });
          dropSwap(tab.id);
          continue;
        }
        const url = pageUrl(tab);
        moved++;
        now.updateTab(tab.id, wantsPage(tab) && url ? { engine: to, page: loadedPage(navigationTo(tab.url || url, true)) } : { engine: to });
      }
    });
    if (singleEngine(store())) useEngineOffers.setState({}, true);
    noteEngineModeChange({ cancelled: false, moved });
    return true;
  } finally {
    useEngineModeSwitch.setState({ pending: null });
  }
}

const visits = visitRecorder(
  (profile, visit) => void addHistoryVisits(profile, [{ url: visit.url, title: visit.title, visitTimes: [visit.at] }]).catch(() => {}),
  { set: (run, ms) => setTimeout(run, ms), clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>) },
  Date.now,
);

const visitedTabs = new Set<string>();
let unwatch: (() => void) | null = null;

function watchClosedTabs() {
  unwatch ??= useBrowser.subscribe((s, prev) => {
    if (s.tabs === prev.tabs) return;
    for (const id of visitedTabs) {
      if (s.tabs[id]) continue;
      visitedTabs.delete(id);
      visits.close(id);
    }
    for (const id of siteMoves.keys()) if (!s.tabs[id]) siteMoves.delete(id);
  });
}

export function noteWebKitPage(tabId: string, page: WebKitPage) {
  const t = store().tabs[tabId];
  if (!t) return;
  watchClosedTabs();
  const firstVisit = !visitedTabs.has(tabId);
  visitedTabs.add(tabId);
  const profile = isIncognitoProfile(t.profileId) ? null : engineProfile(useBrowser.getState(), t.profileId);
  if (firstVisit && profile !== null) void syncExtensionsToWebKit(profile);
  visits.note(tabId, profile, page);
}
